import AppKit
import SwiftUI
import os

/// 遮罩画布：选区状态机 + 全部视觉层。
///
/// 分层设计（性能关键）：整屏冻结图放在**静态**的 `imageLayer` 里永不重绘，
/// 鼠标移动只更新十字线、放大镜、尺寸标签这几个小图层。若把图像画进 `draw(_:)`，
/// 6K 分辨率下每帧都要重新合成整屏，拖动会明显掉帧。
final class OverlayCanvasView: NSView {
    private let logger = Logger(subsystem: "com.ixxxxoooo.jietu", category: "overlay")

    // MARK: - Inputs

    let snapshot: DisplaySnapshot
    private let session: CaptureSession
    private let displayIndex: Int
    private let displayCount: Int

    // MARK: - Callbacks

    var onCancel: (() -> Void)?
    /// 参数是本显示器 local 坐标（point、原点左下）下的选区。
    var onCommit: ((CGRect) -> Void)?
    /// 键盘命令（↵ / 方向键）必须作用在「鼠标所在那块屏」上，
    /// 而多屏时 key window 只会是最后创建的那个，所以焦点要跟着鼠标走。
    var onFocusRequest: (() -> Void)?

    // MARK: - Region pick（滚动长图起步：只要一块选区）

    /// 滚动长图模式：选区**不急着自己交付**——鼠标停住（或松开）就回报，
    /// 由外面的控制条贴着选框下方浮出「手动 / 自动」。
    var isRegionPickMode = false
    /// 窗口截图模式（直接选窗截图，也可按空格在框选与选窗之间切换）。
    var isWindowOnlyMode = false {
        didSet {
            updateHint()
            updateCursor(at: cursorPoint ?? .zero)
            updateWindowHighlight()
        }
    }
    /// 鼠标在选区上停住（或一松手）→ 选区 local 矩形。
    var onSelectionPaused: ((CGRect) -> Void)?
    /// 选区被拖动 / 缩放 / 清空（nil）→ 让控制条跟着选框走。
    var onSelectionChanged: ((CGRect?) -> Void)?
    /// 用户选定某个窗口（单击窗口触发）。
    var onWindowSelected: ((WindowInfo) -> Void)?

    /// 拖动中判定「停住」的时长；停住就浮出工具栏，不必等用户松手。
    private static let regionPickPauseDelay: TimeInterval = 0.35
    private var pauseWorkItem: DispatchWorkItem?

    // MARK: - State

    private enum Interaction {
        case idle
        /// 已按下但还没超过拖拽阈值。
        case pressing(anchor: CGPoint)
        case selecting(anchor: CGPoint)
        /// 已有选区且空闲。
        case settled
        case resizing(handle: SelectionHandle, original: CGRect)
        case moving(grabOffset: CGSize, original: CGRect)
    }

    private var interaction: Interaction = .idle
    private var selection: CGRect?
    private var hoveredWindow: WindowInfo?
    private var cursorPoint: CGPoint?

    // MARK: - Loupe（跟随光标的像素放大镜）

    /// 方形像素网格 + 读数面板：鼠标走到哪跟到哪，用来对着像素抠选区。
    private enum Loupe {
        /// 边长（point）。
        static let side: CGFloat = 136
        /// 网格格数（奇数：光标那一格正好在正中）。
        static let cells = 13
        /// 与光标之间的间距。
        static let gap: CGFloat = 16
    }

    private var sampledColor: PixelSampler.Sample?
    private var lastSampledPixel: CGPoint?

    #if DEBUG
    /// 自检用：最近一次放大镜的状态。
    private var loupeDebugState: DebugLoupeState?
    #endif

    /// 上次用过的选区，按显示器记忆，Tab 恢复。
    private static var rememberedSelection: [CGDirectDisplayID: CGRect] = [:]

    /// 遮罩刚出现时，窗口出现在光标之下会送来一次「按住状态」的杂散 mouseDown
    /// （实测 pressedMouseButtons=1）。用一小段静默期挡掉。
    private var inputArmedAt: TimeInterval = 0

    // MARK: - Inline annotation

    /// 原地编辑模式：选区定下来后不立刻截图，而是在选框下方弹出工具栏原地标注。
    var inlineMode = false
    /// 原地标注完成：参数是已经裁好、并烘焙了标注的最终图，以及选区（local）。
    var onCommitAnnotated: ((CGImage, CGRect) -> Void)?
    /// 进入原地标注时通知 Coordinator（用于同步其它显示器的状态）。
    var onInlineEditingChanged: ((Bool) -> Void)?
    /// 原地工具栏的「下载 / 钉图」回调（钉图额外带选区 local rect，用于原地钉）。
    var onSaveImage: ((CGImage) -> Void)?
    var onPinImage: ((CGImage, CGRect) -> Void)?
    /// 标注默认样式：原地工具栏开出来时用它，改完回报给外部记住。
    var annotationDefaults: AnnotationDefaults = .standard
    var onAnnotationDefaultsChange: ((AnnotationDefaults) -> Void)?

    /// 滚动长图期间：遮罩只当取景框（压暗 + 绿框），冻结图与其它装饰全部收起，
    /// 这样用户能看见下面**真实页面在滚**。
    private var isScrollCaptureChrome = false

    private enum Phase {
        case selecting
        case annotating
    }

    private var phase: Phase = .selecting
    /// 是否正处于原地标注阶段（供 Coordinator 判断 Esc 归属）。
    var isAnnotationPhase: Bool { phase == .annotating }
    private struct EraserStroke {
        var points: [CGPoint]
        var radius: CGFloat
    }

    private struct Snapshot {
        let annotations: [Annotation]
        let strokes: [EraserStroke]
        /// 选区也进快照：标注态里能拖边缘改区域，撤销时必须连选区一起回滚，
        /// 否则标注会按旧原点画在新选区上、整体错位。
        let selection: CGRect?
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var eraserStrokes: [EraserStroke] = []
    private var selectedID: UUID?
    private var erasing = false
    private var lastErasePoint: CGPoint?

    /// 选择工具下的拖拽类型。
    private enum InlineEditDrag {
        case none
        case moving(id: UUID, start: CGPoint, original: Annotation)
        case resizing(id: UUID, handle: ShapeHandle, original: Annotation)
        case rotating(id: UUID, startAngle: CGFloat, original: Annotation)
        case endpoint(id: UUID, handle: ShapeHandle, original: Annotation)
    }

    private var inlineEditDrag: InlineEditDrag = .none
    /// 正在编辑的已有文字对象（nil 表示新建）。
    private var inlineEditingTextID: UUID?
    private let inlineSelectionBorderLayer = CAShapeLayer()
    private let inlineHandlesLayer = CAShapeLayer()
    private var annotations: [Annotation] = []
    private var annotationDraft: Annotation?
    private var previewBase: CGImage?
    private var previewScale: CGFloat = 1
    private var cropImage: CGImage?
    private var liveTextHost: NSView?
    private var toolbarModel: InlineToolbarModel?
    private var mainToolbarHost: NSView?
    private var optionsToolbarHost: NSView?
    private var textField: NSTextField?
    private var inlineDragging = false
    private var inlineStart: CGPoint = .zero

    private let annotationLayer = CALayer()

    // MARK: - Layers

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let windowHighlightLayer = CAShapeLayer()
    private let selectionBorderOuterLayer = CAShapeLayer()
    private let selectionBorderInnerLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let sizeLabelLayer = CATextLayer()
    private let windowLabelLayer = CATextLayer()
    private let hintLayer = CATextLayer()

    // 放大镜：图 + 网格 + 十字带 + 中心格 + 边框，读数面板单独几层。
    private let loupeShadowLayer = CAShapeLayer()
    private let loupeBorderLayer = CAShapeLayer()
    private let loupeImageLayer = CALayer()
    private let loupeGridDarkLayer = CAShapeLayer()
    private let loupeGridLightLayer = CAShapeLayer()
    private let loupeGuideLayer = CAShapeLayer()
    private let loupeCellShadowLayer = CAShapeLayer()
    private let loupeCellLayer = CAShapeLayer()
    private let loupePanelLayer = CALayer()
    private let loupeCoordinateLayer = CATextLayer()
    private let loupeRegionLayer = CATextLayer()
    private let loupeColorLayer = CATextLayer()
    private let loupeSwatchLayer = CALayer()

    private var trackingArea: NSTrackingArea?

    // MARK: - Init

    init(
        snapshot: DisplaySnapshot,
        session: CaptureSession,
        displayIndex: Int,
        displayCount: Int
    ) {
        self.snapshot = snapshot
        self.session = session
        self.displayIndex = displayIndex
        self.displayCount = displayCount
        super.init(frame: NSRect(origin: .zero, size: snapshot.screenFrameInPoints.size))
        wantsLayer = true
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func armInput(after delay: TimeInterval) {
        inputArmedAt = CACurrentMediaTime() + delay
    }

    /// 遮罩刚出现时先点亮鼠标所在窗口。
    ///
    /// 不做这一步的话，第一帧是**整屏压暗**（还没有 hover 过任何窗口），
    /// 要等用户动一下鼠标才亮起来——看起来就像「一上来先糊了一层遮罩」。
    func primeHoveredWindow() {
        let local = convert(NSEvent.mouseLocation, from: nil)
        guard canvasBounds.contains(local) else { return }
        updateHoveredWindow(at: local)
        updateWindowHighlight()
    }

    private var isInputArmed: Bool {
        CACurrentMediaTime() >= inputArmedAt
    }

    private var canvasBounds: CGRect {
        CGRect(origin: .zero, size: snapshot.screenFrameInPoints.size)
    }

    private func requestFocusIfNeeded() {
        guard let window, !window.isKeyWindow else { return }
        onFocusRequest?()
    }

    private var isSettled: Bool {
        if case .settled = interaction { return true }
        return false
    }

    #if DEBUG
    /// 自检用：当前选区（本显示器 local 坐标）。
    var debugSelection: CGRect? { selection }

    /// 自检用：跳过鼠标直接摆一个选区。
    func debugSetSelection(_ rect: CGRect) {
        selection = rect
        interaction = .settled
        updateAllLayers()
    }

    /// 自检用：放大镜的「模型 frame」与「当前呈现 frame」。
    ///
    /// 有隐式动画时两者会不同（呈现值还在半路上）——用来盯住「跟随光标不该有动画」。
    var debugLoupePresentation: (model: CGRect, presentation: CGRect?, isHidden: Bool) {
        (
            model: loupeImageLayer.frame,
            presentation: loupeImageLayer.presentation()?.frame,
            isHidden: loupeImageLayer.isHidden
        )
    }

    /// 自检用：放大镜当前取的是哪一块像素、光标落在哪一格。
    struct DebugLoupeState {
        /// 放大镜在画布（本显示器 local，原点左下）里的位置。
        let frame: CGRect
        /// 采样窗口在图像里的左上角（图像像素、原点左上）。
        let sourceOrigin: CGPoint
        /// 光标像素（图像像素、原点左上）。
        let cursorPixel: CGPoint
        /// 光标的像素格子在放大镜里的位置（左上角为 0）。
        let cell: CGPoint
        /// 当前格子的格边长（point）。
        let cellSide: CGFloat
        /// 取到的颜色。
        let hex: String?
    }

    var debugLoupeState: DebugLoupeState? {
        guard !loupeImageLayer.isHidden else { return nil }
        guard let state = loupeDebugState else { return nil }
        return state
    }
    #endif

    // MARK: - Region pick 回报

    /// 选区成型且「像样」才值得浮出工具栏（太小的一块按不出来）。
    private var isSelectionUsable: Bool {
        guard let selection else { return false }
        return selection.width >= Theme.minimumSelectionSize
            && selection.height >= Theme.minimumSelectionSize
    }

    /// 拖动中重新计时：停住 `regionPickPauseDelay` 就回报「可以出工具栏了」。
    private func schedulePauseSignal() {
        guard isRegionPickMode else { return }
        pauseWorkItem?.cancel()
        pauseWorkItem = nil
        guard isSelectionUsable else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isRegionPickMode, let rect = self.selection else { return }
            self.onSelectionPaused?(rect)
        }
        pauseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.regionPickPauseDelay, execute: item)
    }

    /// 立刻回报（松手 / ↵）：不等那 0.35 秒。
    private func firePauseSignal() {
        guard isRegionPickMode, let selection else { return }
        cancelPauseSignal()
        onSelectionPaused?(selection)
    }

    private func cancelPauseSignal() {
        pauseWorkItem?.cancel()
        pauseWorkItem = nil
    }

    /// 选区变了（拖动 / 缩放 / 清空）→ 控制条贴着新选框走。
    private func notifySelectionChanged() {
        guard isRegionPickMode else { return }
        onSelectionChanged?(selection)
    }

    // MARK: - Layer setup

    private func configureLayers() {
        guard let root = layer else { return }
        let scale = window?.backingScaleFactor ?? snapshot.nominalScaleFactor

        imageLayer.contents = snapshot.image
        imageLayer.contentsGravity = .resize
        imageLayer.contentsScale = scale
        imageLayer.magnificationFilter = .nearest
        imageLayer.frame = bounds
        root.addSublayer(imageLayer)

        // 原地标注层：叠在冻结图之上、压暗层之下（选区被挖空，所以标注可见）。
        annotationLayer.frame = bounds
        annotationLayer.contentsGravity = .resize
        annotationLayer.magnificationFilter = .nearest
        annotationLayer.isHidden = true
        // 关闭隐式动画：否则设置 contents/frame 会有 0.25s 过渡，表现为「闪一下」。
        annotationLayer.actions = [
            "contents": NSNull(),
            "frame": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull(),
            "opacity": NSNull(),
        ]
        root.addSublayer(annotationLayer)

        // 原地选择态：虚线包围盒 + 控制点。
        inlineSelectionBorderLayer.fillColor = nil
        inlineSelectionBorderLayer.strokeColor = NSColor(Theme.selectionGreen).cgColor
        inlineSelectionBorderLayer.lineWidth = 1.2
        inlineSelectionBorderLayer.lineDashPattern = [5, 3]
        inlineSelectionBorderLayer.isHidden = true
        root.addSublayer(inlineSelectionBorderLayer)

        inlineHandlesLayer.fillColor = NSColor.white.cgColor
        inlineHandlesLayer.strokeColor = NSColor(Theme.selectionGreen).cgColor
        inlineHandlesLayer.lineWidth = 1.2
        inlineHandlesLayer.isHidden = true
        root.addSublayer(inlineHandlesLayer)

        dimLayer.fillColor = NSColor.black
            .withAlphaComponent(Theme.overlayDimAlpha).cgColor
        dimLayer.fillRule = .evenOdd
        dimLayer.frame = bounds
        root.addSublayer(dimLayer)

        // 吸附预览（自动识别窗口边界）：**只描边、不填色**。
        // 之前压了一层 6% 的绿：窗口一大（满屏窗口）整块屏幕都跟着泛绿。
        windowHighlightLayer.fillColor = nil
        windowHighlightLayer.strokeColor = NSColor(Theme.selectionGreen).cgColor
        windowHighlightLayer.lineWidth = 3
        windowHighlightLayer.isHidden = true
        windowHighlightLayer.frame = bounds
        root.addSublayer(windowHighlightLayer)

        // 绿色虚线选框（参考 CleanShot）。
        configureBorderLayer(selectionBorderOuterLayer, color: NSColor(Theme.selectionGreen))
        selectionBorderOuterLayer.lineWidth = 1.5
        selectionBorderOuterLayer.lineDashPattern = [6, 4]
        configureBorderLayer(selectionBorderInnerLayer, color: .clear)
        root.addSublayer(selectionBorderOuterLayer)
        root.addSublayer(selectionBorderInnerLayer)

        handlesLayer.fillColor = NSColor(Theme.selectionGreen).cgColor
        handlesLayer.strokeColor = NSColor.white.cgColor
        handlesLayer.lineWidth = 1
        handlesLayer.frame = bounds
        root.addSublayer(handlesLayer)

        // 关闭这些图层的隐式动画：否则隐藏/改 path 时会有淡入淡出或缩放过渡。
        let noActions: [String: CAAction] = [
            "path": NSNull(),
            "hidden": NSNull(),
            "opacity": NSNull(),
            "contents": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull(),
        ]
        for layer in [
            dimLayer, windowHighlightLayer, selectionBorderOuterLayer,
            selectionBorderInnerLayer, handlesLayer, crosshairLayer,
            inlineSelectionBorderLayer, inlineHandlesLayer,
        ] {
            layer.actions = noActions
        }

        crosshairLayer.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        crosshairLayer.lineWidth = 1
        crosshairLayer.fillColor = nil
        crosshairLayer.frame = bounds
        root.addSublayer(crosshairLayer)


        for textLayer in [sizeLabelLayer, windowLabelLayer, hintLayer] {
            configurePillTextLayer(textLayer, scale: scale)
            root.addSublayer(textLayer)
        }
        windowLabelLayer.isHidden = true

        configureLoupe(scale: scale, root: root)
        updateAllLayers()
    }

    /// 放大镜各层：图（nearest，硬边像素）+ 两层网格（深浅内容上都看得见）
    /// + 十字带 + 中心格描边 + 外框，读数面板单独几层。
    ///
    /// 外框不用「粗描边圈一圈」——那是块状灰边，厚且糊。改成论坛通用的浮空做法：
    /// 一层柔和投影托起来 + 一根 1px 发丝线（外侧白、内侧墨），转角走 `.continuous`。
    private func configureLoupe(scale: CGFloat, root: CALayer) {
        // 投影载体：本身被上面的图完全盖住，只为投出阴影。
        loupeShadowLayer.fillColor = NSColor.black.cgColor
        loupeShadowLayer.strokeColor = nil
        loupeShadowLayer.shadowColor = NSColor.black.cgColor
        loupeShadowLayer.shadowOpacity = 0.38
        loupeShadowLayer.shadowRadius = 12
        loupeShadowLayer.shadowOffset = CGSize(width: 0, height: -4)
        loupeShadowLayer.cornerRadius = Theme.Radius.card
        loupeShadowLayer.cornerCurve = .continuous

        // 外圈发丝线：深色内容上把边界提出来。
        loupeBorderLayer.fillColor = nil
        loupeBorderLayer.strokeColor = nil
        loupeBorderLayer.backgroundColor = nil
        loupeBorderLayer.borderWidth = 1
        loupeBorderLayer.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        loupeBorderLayer.cornerRadius = Theme.Radius.card
        loupeBorderLayer.cornerCurve = .continuous

        loupeImageLayer.contents = snapshot.image
        loupeImageLayer.contentsGravity = .resize
        loupeImageLayer.magnificationFilter = .nearest
        loupeImageLayer.minificationFilter = .nearest
        loupeImageLayer.cornerRadius = Theme.Radius.card
        loupeImageLayer.cornerCurve = .continuous
        loupeImageLayer.masksToBounds = true
        loupeImageLayer.contentsScale = scale
        // 内圈发丝线：浅色内容上把边界提出来（与上一条一深一浅，任何底色都看得见）。
        loupeImageLayer.borderWidth = 1
        loupeImageLayer.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor

        loupeGridDarkLayer.fillColor = nil
        loupeGridDarkLayer.strokeColor = NSColor.black.withAlphaComponent(0.28).cgColor
        loupeGridDarkLayer.lineWidth = 0.5
        loupeGridLightLayer.fillColor = nil
        loupeGridLightLayer.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        loupeGridLightLayer.lineWidth = 0.5

        // 十字带：光标那一行 / 一列整条淡淡染一下（品牌绿），中心格再描一圈白的。
        loupeGuideLayer.fillColor = NSColor(Theme.selectionGreen)
            .withAlphaComponent(0.16).cgColor
        loupeGuideLayer.strokeColor = nil
        loupeCellShadowLayer.fillColor = nil
        loupeCellShadowLayer.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
        loupeCellShadowLayer.lineWidth = 2
        loupeCellLayer.fillColor = nil
        loupeCellLayer.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        loupeCellLayer.lineWidth = 1.5

        for layer in [
            loupeShadowLayer, loupeBorderLayer, loupeImageLayer, loupeGridDarkLayer,
            loupeGridLightLayer, loupeGuideLayer, loupeCellShadowLayer, loupeCellLayer,
        ] {
            layer.isHidden = true
            layer.actions = Self.loupeNoActions
            root.addSublayer(layer)
        }

        // 读数面板：深墨压底（内容什么颜色都得读得清）+ `Radius.card` 圆角
        // + ramp 的 `border` 发丝线 + 一层柔和投影，和浮窗 / 工具栏同一套观感。
        loupePanelLayer.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        loupePanelLayer.cornerRadius = Theme.Radius.card
        loupePanelLayer.cornerCurve = .continuous
        loupePanelLayer.borderWidth = 1
        loupePanelLayer.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        loupePanelLayer.shadowColor = NSColor.black.cgColor
        loupePanelLayer.shadowOpacity = 0.35
        loupePanelLayer.shadowRadius = 10
        loupePanelLayer.shadowOffset = CGSize(width: 0, height: -3)
        loupePanelLayer.isHidden = true
        loupePanelLayer.actions = Self.loupeNoActions
        root.addSublayer(loupePanelLayer)

        for textLayer in [loupeCoordinateLayer, loupeRegionLayer, loupeColorLayer] {
            textLayer.fontSize = 11
            textLayer.alignmentMode = .left
            textLayer.truncationMode = .none
            textLayer.contentsScale = scale
            textLayer.isHidden = true
            textLayer.actions = Self.loupeNoActions
            root.addSublayer(textLayer)
        }
        loupeSwatchLayer.cornerRadius = Theme.Radius.glyph
        loupeSwatchLayer.cornerCurve = .continuous
        loupeSwatchLayer.borderWidth = 1
        loupeSwatchLayer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        loupeSwatchLayer.isHidden = true
        loupeSwatchLayer.actions = Self.loupeNoActions
        root.addSublayer(loupeSwatchLayer)
    }

    /// 读数行：标签走 ramp 的次级墨（0.60），数值走主墨（1.00）+ 等宽数字
    /// （数值跟着光标刷新，等宽才不会左右抖）。
    private static func loupeReadoutRow(label: String, value: String) -> NSAttributedString {
        let row = NSMutableAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.60),
            ]
        )
        row.append(
            NSAttributedString(
                string: value,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
            )
        )
        return row
    }

    /// 放大镜全程跟手：**关掉隐式动画**。
    ///
    /// 否则第一次显示时图层从 `(0,0)`（图层坐标的左下角）动画到光标处，
    /// 看起来就是「放大镜从左下角滑过来」；跟着鼠标移动也会慢半拍。
    private static let loupeNoActions: [String: CAAction] = [
        "hidden": NSNull(), "opacity": NSNull(), "contents": NSNull(),
        "contentsRect": NSNull(), "path": NSNull(), "fillColor": NSNull(),
        "strokeColor": NSNull(), "lineWidth": NSNull(), "backgroundColor": NSNull(),
        "cornerRadius": NSNull(), "borderWidth": NSNull(), "borderColor": NSNull(),
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "string": NSNull(),
    ]

    private func configureBorderLayer(_ layer: CAShapeLayer, color: NSColor) {
        layer.fillColor = nil
        layer.strokeColor = color.cgColor
        layer.lineWidth = 1
        layer.isHidden = true
        layer.frame = bounds
    }

    private func configurePillTextLayer(_ textLayer: CATextLayer, scale: CGFloat) {
        textLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        textLayer.fontSize = 11
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        textLayer.cornerRadius = 6
        textLayer.masksToBounds = true
        textLayer.alignmentMode = .center
        textLayer.contentsScale = scale
        textLayer.isHidden = true
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? snapshot.nominalScaleFactor
        for layer in [
            imageLayer, dimLayer, windowHighlightLayer, selectionBorderOuterLayer,
            selectionBorderInnerLayer, handlesLayer, crosshairLayer,
            inlineSelectionBorderLayer, inlineHandlesLayer,
        ] {
            layer.frame = bounds
        }
        imageLayer.contentsScale = scale
        // 标注层尺寸由 updateAnnotationLayer() 按选区设置，这里不能重置成整屏。
        annotationLayer.contentsScale = scale
        for textLayer in [
            sizeLabelLayer, windowLabelLayer, hintLayer,
            loupeCoordinateLayer, loupeRegionLayer, loupeColorLayer,
        ] {
            textLayer.contentsScale = scale
        }
        updateAllLayers()
        layoutToolbars()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                .activeAlways, .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// 切换「滚动长图取景框」外观（只留压暗 + 选区绿框，窗口由控制器设为鼠标穿透）。
    func setScrollCaptureChrome(_ on: Bool) {
        isScrollCaptureChrome = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 冻结图收起 → 露出下面实时画面；dimLayer / 选区边框保留 → 就是取景框。
        imageLayer.isHidden = on
        annotationLayer.isHidden = on
        handlesLayer.isHidden = on
        inlineSelectionBorderLayer.isHidden = on
        inlineHandlesLayer.isHidden = on
        windowHighlightLayer.isHidden = true
        sizeLabelLayer.isHidden = on
        hintLayer.isHidden = on
        crosshairLayer.isHidden = on
        crosshairLayer.path = nil
        updateLoupe()
        CATransaction.commit()
    }

    // MARK: - Rendering

    private func updateAllLayers() {
        updateDimPath()
        updateSelectionLayers()
        updateCrosshair()
        updateLoupe()
        updateHint()
    }

    private func updateDimPath() {
        let path = CGMutablePath()
        path.addRect(bounds)
        // even-odd 挖洞：有选区就挖选区，没选区但吸附到窗口就按圆角矩形挖出该窗口，
        // 让用户先看到清晰明亮的将截窗口内容。
        if let selection {
            path.addRect(selection)
        } else if let windowRect = hoveredWindowLocalRect {
            path.addPath(CGPath(roundedRect: windowRect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        }
        dimLayer.path = path
    }

    private var dimHoleRect: CGRect? {
        if let selection { return selection }
        return hoveredWindowLocalRect
    }

    /// 鼠标下窗口在本显示器内的矩形（已裁进画布），没有则 nil。
    ///
    /// 只在「还没有选区」时用于悬停预览；一旦点选/框选成型就收起高亮，
    /// 选中的窗口不再有蓝色染色（与框选保持一致）。
    private var hoveredWindowLocalRect: CGRect? {
        guard !isSettled, selection == nil, let hoveredWindow else { return nil }
        let rect = DisplayGeometry.localRect(
            fromCGRect: hoveredWindow.frameInCGPoints,
            screen: screen
        )
        let clipped = rect.intersection(canvasBounds)
        return clipped.isEmpty ? nil : clipped
    }

    private func updateSelectionLayers() {
        guard let selection else {
            selectionBorderOuterLayer.isHidden = true
            selectionBorderInnerLayer.isHidden = true
            handlesLayer.path = nil
            sizeLabelLayer.isHidden = true
            return
        }

        selectionBorderOuterLayer.isHidden = false
        selectionBorderInnerLayer.isHidden = true
        // 绿色虚线选框。
        selectionBorderOuterLayer.path = CGPath(rect: selection, transform: nil)

        let path = CGMutablePath()
        let size = Theme.selectionHandleSize
        for handle in SelectionHandle.allCases {
            let center = handle.center(in: selection)
            // 圆形控制点。
            path.addPath(
                CGPath(
                    ellipseIn: CGRect(
                        x: center.x - size / 2,
                        y: center.y - size / 2,
                        width: size,
                        height: size
                    ),
                    transform: nil
                )
            )
        }
        handlesLayer.path = path

        updateSizeLabel(selection)
    }

    private func updateSizeLabel(_ selection: CGRect) {
        guard !isScrollCaptureChrome else { return }
        let pixelSize = CGSize(
            width: (selection.width * snapshot.effectiveScale).rounded(),
            height: (selection.height * snapshot.effectiveScale).rounded()
        )
        let text = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
        let width = max(96, CGFloat(text.count) * 7.2 + 16)
        let height: CGFloat = 20

        // 优先放在选区内部左上；放不下就移到选区上方外侧。
        var origin = CGPoint(x: selection.minX + 6, y: selection.maxY - height - 6)
        if selection.width < width + 12 {
            origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        }
        origin.x = min(max(origin.x, bounds.minX + 2), bounds.maxX - width - 2)
        origin.y = min(max(origin.y, bounds.minY + 2), bounds.maxY - height - 2)

        sizeLabelLayer.string = text
        sizeLabelLayer.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        sizeLabelLayer.isHidden = false
    }

    private func updateCrosshair() {
        guard !isScrollCaptureChrome else { return }
        // 选区定型后收起十字线，避免干扰阅读选框内容。
        guard let cursorPoint, !isSettled else {
            crosshairLayer.path = nil
            return
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX, y: cursorPoint.y))
        path.addLine(to: CGPoint(x: bounds.maxX, y: cursorPoint.y))
        path.move(to: CGPoint(x: cursorPoint.x, y: bounds.minY))
        path.addLine(to: CGPoint(x: cursorPoint.x, y: bounds.maxY))
        crosshairLayer.path = path
    }

    // MARK: - Loupe

    private var loupeLayers: [CALayer] {
        [
            loupeShadowLayer, loupeBorderLayer, loupeImageLayer, loupeGridDarkLayer,
            loupeGridLightLayer, loupeGuideLayer, loupeCellShadowLayer, loupeCellLayer,
            loupePanelLayer, loupeCoordinateLayer, loupeRegionLayer, loupeColorLayer,
            loupeSwatchLayer,
        ]
    }

    /// 放大镜：跟着光标，只在「还没定选区」的框选阶段出现。
    private func updateLoupe() {
        CATransaction.begin()
        // 跟手的东西一律不走隐式动画（见 loupeNoActions）：否则首帧会从图层原点滑过来。
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let shouldShow = cursorPoint != nil && !isSettled && !isScrollCaptureChrome
            && phase == .selecting
        for layer in loupeLayers {
            layer.isHidden = !shouldShow
        }
        guard shouldShow, let cursorPoint else { return }

        let image = snapshot.image
        let side = Loupe.side
        let cells = CGFloat(Loupe.cells)
        let cellSide = side / cells
        // 光标所在的图像像素（原点左上）。
        let center = snapshot.pixelPoint(fromLocalPoint: cursorPoint)
        let cursorPixel = CGPoint(x: center.x.rounded(.down), y: center.y.rounded(.down))

        // 以光标像素为正中取一格窗口；贴边时把窗口夹回图像内（光标格会随之偏离中心）。
        let span = CGFloat(Loupe.cells - 1) / 2
        let originX = min(
            max(cursorPixel.x - span, 0), max(0, CGFloat(image.width) - cells)
        )
        let originY = min(
            max(cursorPixel.y - span, 0), max(0, CGFloat(image.height) - cells)
        )
        loupeImageLayer.contentsRect = LoupeGeometry.contentsRect(
            sourceOrigin: CGPoint(x: originX, y: originY),
            cells: Loupe.cells,
            imageSize: snapshot.pixelSize
        )

        let cellX = min(max(cursorPixel.x - originX, 0), cells - 1)
        let cellY = min(max(cursorPixel.y - originY, 0), cells - 1)
        let cellRect = CGRect(
            x: cellX * cellSide,
            y: side - (cellY + 1) * cellSide,
            width: cellSide,
            height: cellSide
        )
        loupeGridDarkLayer.path = Self.loupeGridPath
        loupeGridLightLayer.path = Self.loupeGridPath
        let guide = CGMutablePath()
        guide.addRect(CGRect(x: 0, y: cellRect.minY, width: side, height: cellSide))
        guide.addRect(CGRect(x: cellRect.minX, y: 0, width: cellSide, height: side))
        loupeGuideLayer.path = guide
        loupeCellShadowLayer.path = CGPath(rect: cellRect, transform: nil)
        loupeCellLayer.path = CGPath(rect: cellRect, transform: nil)

        // 跟在光标右上角，贴边时翻到另一侧并夹在屏幕内。
        var origin = CGPoint(x: cursorPoint.x + Loupe.gap, y: cursorPoint.y + Loupe.gap)
        if origin.x + side > bounds.maxX - 8 { origin.x = cursorPoint.x - Loupe.gap - side }
        if origin.y + side > bounds.maxY - 8 { origin.y = cursorPoint.y - Loupe.gap - side }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - side - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - side - 8)
        let frame = CGRect(origin: origin, size: CGSize(width: side, height: side))

        for layer in [
            loupeShadowLayer, loupeBorderLayer, loupeImageLayer, loupeGridDarkLayer,
            loupeGridLightLayer, loupeGuideLayer, loupeCellShadowLayer, loupeCellLayer,
        ] {
            layer.frame = frame
        }
        // 外框 / 投影都走 `cornerRadius`（不再描 path），转角才是 `.continuous` 的 squircle。
        loupeShadowLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerWidth: Theme.Radius.card, cornerHeight: Theme.Radius.card, transform: nil
        )

        updateLoupeReadout(frame: frame, pixel: cursorPixel)
        #if DEBUG
        loupeDebugState = DebugLoupeState(
            frame: frame,
            sourceOrigin: CGPoint(x: originX, y: originY),
            cursorPixel: cursorPixel,
            cell: CGPoint(x: cellX, y: cellY),
            cellSide: cellSide,
            hex: sampledColor?.hexString
        )
        #endif
    }

    /// 网格线固定（边长与格数都是常量），算一次就够，别每帧重建 24 条线段。
    private static let loupeGridPath: CGPath = {
        let cellSide = Loupe.side / CGFloat(Loupe.cells)
        let path = CGMutablePath()
        for index in 1..<Loupe.cells {
            let offset = CGFloat(index) * cellSide
            path.move(to: CGPoint(x: offset, y: 0))
            path.addLine(to: CGPoint(x: offset, y: Loupe.side))
            path.move(to: CGPoint(x: 0, y: offset))
            path.addLine(to: CGPoint(x: Loupe.side, y: offset))
        }
        return path
    }()

    /// 读数面板：坐标 / 区域 / 色值，贴在放大镜下方（放不下就挪到上方）。
    private func updateLoupeReadout(frame: CGRect, pixel: CGPoint) {
        // 只在跨过像素时才重新取样，天然节流。
        if lastSampledPixel != pixel {
            lastSampledPixel = pixel
            sampledColor = PixelSampler.sample(snapshot.image, atPixel: pixel)
        }

        let coordinate = Self.loupeReadoutRow(
            label: "坐标: ", value: String(format: "(%.0f, %.0f)", pixel.x, pixel.y)
        )
        // 「区域」= 现在按下去会截到的那块：选框 / 悬停窗口，都没有就显示占位。
        let regionPoints = selection ?? hoveredWindowLocalRect
        let region = Self.loupeReadoutRow(
            label: "区域: ",
            value: regionPoints.map {
                String(
                    format: "%.0f × %.0f",
                    ($0.width * snapshot.effectiveScale).rounded(),
                    ($0.height * snapshot.effectiveScale).rounded()
                )
            } ?? "—"
        )
        let colorRow = Self.loupeReadoutRow(
            label: "色值: ", value: sampledColor?.hexString ?? "—"
        )
        let rows = [coordinate, region, colorRow]

        let inset = Theme.Spacing.md
        let rowHeight: CGFloat = 15
        let swatchSize: CGFloat = 12
        let textWidth = rows.map(Self.loupeTextWidth).max() ?? 0
        let panelWidth = min(
            bounds.width - Theme.Spacing.md * 2,
            max(Loupe.side, textWidth + inset * 2 + swatchSize + Theme.Spacing.sm)
        )
        // 上下留白对称（原来下面靠 -4 硬凑，看着挤）。
        let panelHeight = rowHeight * CGFloat(rows.count) + inset * 2

        var panelY = frame.minY - panelHeight - Theme.Spacing.xs
        if panelY < bounds.minY + Theme.Spacing.md {
            panelY = frame.maxY + Theme.Spacing.xs
        }
        panelY = min(
            max(panelY, bounds.minY + Theme.Spacing.md),
            bounds.maxY - panelHeight - Theme.Spacing.md
        )
        let panelX = min(
            max(frame.minX, bounds.minX + Theme.Spacing.md),
            max(bounds.minX + Theme.Spacing.md, bounds.maxX - panelWidth - Theme.Spacing.md)
        )
        let panelFrame = CGRect(
            x: panelX, y: panelY, width: panelWidth, height: panelHeight
        )
        loupePanelLayer.frame = panelFrame

        let rowsTop = panelFrame.maxY - inset
        for (index, layer) in [loupeCoordinateLayer, loupeRegionLayer, loupeColorLayer]
            .enumerated()
        {
            layer.string = rows[index]
            layer.frame = CGRect(
                x: panelFrame.minX + inset,
                y: rowsTop - CGFloat(index + 1) * rowHeight,
                width: panelWidth - inset * 2,
                height: rowHeight
            )
        }

        if let sampledColor {
            loupeSwatchLayer.isHidden = false
            loupeSwatchLayer.backgroundColor = NSColor(
                srgbRed: CGFloat(sampledColor.red) / 255,
                green: CGFloat(sampledColor.green) / 255,
                blue: CGFloat(sampledColor.blue) / 255,
                alpha: 1
            ).cgColor
        } else {
            loupeSwatchLayer.isHidden = true
        }
        loupeSwatchLayer.frame = CGRect(
            x: panelFrame.minX + inset + Self.loupeTextWidth(colorRow) + Theme.Spacing.sm,
            y: rowsTop - 3 * rowHeight + (rowHeight - swatchSize) / 2,
            width: swatchSize,
            height: swatchSize
        )
        for layer in [loupeCoordinateLayer, loupeRegionLayer, loupeColorLayer, loupePanelLayer] {
            layer.isHidden = false
        }
    }

    private static func loupeTextWidth(_ text: NSAttributedString) -> CGFloat {
        ceil(text.size().width)
    }

    private func updateWindowHighlight() {
        // 压暗层也要跟着重算（洞口就是被吸附的窗口）。
        updateDimPath()

        guard let window = hoveredWindow, let clipped = hoveredWindowLocalRect else {
            windowHighlightLayer.isHidden = true
            windowLabelLayer.isHidden = true
            return
        }

        windowHighlightLayer.isHidden = false
        windowHighlightLayer.path = CGPath(roundedRect: clipped, cornerWidth: 10, cornerHeight: 10, transform: nil)

        let text = "\(window.displayName)   \(Int(window.frameInCGPoints.width))×\(Int(window.frameInCGPoints.height))"
        let width = min(bounds.width - 20, max(120, CGFloat(text.count) * 7.2 + 16))
        let height: CGFloat = 20
        let origin = CGPoint(
            x: min(max(clipped.minX, bounds.minX + 6), bounds.maxX - width - 6),
            y: max(clipped.maxY - height - 6, bounds.minY + 6)
        )
        windowLabelLayer.string = text
        windowLabelLayer.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        windowLabelLayer.alignmentMode = .center
        windowLabelLayer.isHidden = false
    }

    private func updateHint() {
        guard !isScrollCaptureChrome else { return }
        let size = snapshot.pixelSize
        var text = String(
            format: "显示器 %d/%d  ·  %.0f×%.0f px  ·  缩放 %.2fx",
            displayIndex,
            displayCount,
            size.width,
            size.height,
            snapshot.effectiveScale
        )
        if isRegionPickMode {
            text += selection == nil
                ? "  ·  拖拽框选（鼠标停住出「手动 / 自动」）  ·  Esc 取消"
                : "  ·  鼠标停住出「手动 / 自动」，选区还能接着调  ·  Esc 取消"
        } else if isWindowOnlyMode {
            text += "  ·  点击窗口截图  ·  ␣ 切换自由框选  ·  Esc 取消"
        } else {
            text += selection == nil
                ? "  ·  拖拽框选 / 点窗口截整窗  ·  ␣ 切换窗口模式  ·  Esc 取消"
                : "  ·  ↵ 完成, ⇥ 上次选区, ⇧ 正方形  ·  Esc 取消"
        }
        let width = min(bounds.width - 40, max(420, CGFloat(text.count) * 7.4))
        hintLayer.string = text
        hintLayer.frame = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.maxY - 56,
            width: width,
            height: 24
        )
    }

    // MARK: - Hit testing

    private var screen: NSScreen {
        NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID }
            ?? NSScreen.screens.first
            ?? NSScreen.main!
    }

    private func updateHoveredWindow(at point: CGPoint) {
        let cgPoint = DisplayGeometry.cgPoint(fromLocal: point, screen: screen)
        let hit = WindowHitTester.frontmost(atCGPoint: cgPoint, in: session.windows)
        #if DEBUG
        if hit?.windowID != hoveredWindow?.windowID {
            print(
                "[canvas \(snapshot.displayID)] hover local=\(Self.describe(point))"
                    + " cg=\(Self.describe(cgPoint))"
                    + " -> \(hit.map { "\($0.ownerName)/\($0.title)" } ?? "nil")"
                    + " of \(session.windows.count) windows"
            )
        }
        #endif
        guard hit?.windowID != hoveredWindow?.windowID else { return }
        hoveredWindow = hit
        updateWindowHighlight()
    }

    #if DEBUG
    private static func describe(_ point: CGPoint) -> String {
        String(format: "(%.0f,%.0f)", point.x, point.y)
    }
    #endif

    private static let cameraCursor: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        if let img = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = NSSize(width: 24, height: 24)
            let canvas = NSImage(size: size, flipped: false) { rect in
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.shadowBlurRadius = 2
                shadow.set()
                NSColor.white.set()
                img.draw(in: NSRect(x: 2, y: 2, width: 20, height: 20))
                return true
            }
            return NSCursor(image: canvas, hotSpot: NSPoint(x: 12, y: 12))
        }
        return .crosshair
    }()

    private func updateCursor(at point: CGPoint) {
        if isWindowOnlyMode {
            Self.cameraCursor.set()
            return
        }
        if let selection, let handle = SelectionGeometry.handle(
            at: point,
            in: selection,
            tolerance: Theme.selectionHandleHitTolerance
        ) {
            SelectionCursor.cursor(for: handle).set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInputArmed else { return }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isWindowOnlyMode ? Self.cameraCursor : .crosshair)
    }

    // MARK: - Events

    override func mouseMoved(with event: NSEvent) {
        guard isInputArmed else { return }
        requestFocusIfNeeded()
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        updateHoveredWindow(at: point)
        updateCrosshair()
        updateLoupe()
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        hoveredWindow = nil
        updateWindowHighlight()
        updateCrosshair()
        updateLoupe()
    }

    override func mouseDown(with event: NSEvent) {
        guard isInputArmed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            requestFocusIfNeeded()
            cursorPoint = point
            // 选区边缘优先接管：绿框还在，抓着边缘就是继续调区域，框内照旧用来标注。
            if let selection,
                let handle = SelectionGeometry.handle(
                    at: point,
                    in: selection,
                    tolerance: Theme.selectionHandleHitTolerance
                )
            {
                // 整段拖拽算一步撤销。
                pushUndo()
                interaction = .resizing(handle: handle, original: selection)
                return
            }
            inlineMouseDown(point, clickCount: event.clickCount)
            return
        }
        requestFocusIfNeeded()
        cursorPoint = point

        if isWindowOnlyMode {
            interaction = .pressing(anchor: point)
            return
        }

        if let selection {
            if let handle = SelectionGeometry.handle(
                at: point,
                in: selection,
                tolerance: Theme.selectionHandleHitTolerance
            ) {
                interaction = .resizing(handle: handle, original: selection)
                return
            }
            if selection.contains(point) {
                if event.clickCount >= 2 {
                    if isRegionPickMode {
                        firePauseSignal()
                    } else {
                        commit()
                    }
                    return
                }
                interaction = .moving(
                    grabOffset: CGSize(
                        width: point.x - selection.minX,
                        height: point.y - selection.minY
                    ),
                    original: selection
                )
                return
            }
            // 在选区外按下：清掉旧选区，开始框新的。
            self.selection = nil
            updateAllLayers()
            notifySelectionChanged()
        }

        interaction = .pressing(anchor: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInputArmed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            // 正在拖选区边缘 → 继续改区域；否则交给原地标注。
            if case .resizing(let handle, let original) = interaction {
                cursorPoint = point
                let updated = SelectionGeometry.resized(
                    original,
                    handle: handle,
                    to: point,
                    clampTo: canvasBounds,
                    lockAspect: event.modifierFlags.contains(.shift)
                )
                // 用「上一次的选区」算增量：每次拖拽事件都只平移一次。
                applyRegionResize(from: selection ?? original, to: updated)
                return
            }
            inlineMouseDragged(point)
            return
        }
        cursorPoint = point
        let lockAspect = event.modifierFlags.contains(.shift)

        switch interaction {
        case .pressing(let anchor):
            // 窗口专选模式下禁止拖出自由选区
            guard !isWindowOnlyMode else { break }
            if hypot(point.x - anchor.x, point.y - anchor.y) >= Theme.dragActivationDistance {
                interaction = .selecting(anchor: anchor)
                selection = SelectionGeometry.selectionRect(
                    from: anchor,
                    to: point,
                    clampTo: canvasBounds,
                    square: lockAspect
                )
            }
        case .selecting(let anchor):
            selection = SelectionGeometry.selectionRect(
                from: anchor,
                to: point,
                clampTo: canvasBounds,
                square: lockAspect
            )
        case .resizing(let handle, let original):
            selection = SelectionGeometry.resized(
                original,
                handle: handle,
                to: point,
                clampTo: canvasBounds,
                lockAspect: lockAspect
            )
        case .moving(let grabOffset, let original):
            let delta = CGSize(
                width: point.x - original.minX - grabOffset.width,
                height: point.y - original.minY - grabOffset.height
            )
            selection = SelectionGeometry.moved(original, by: delta, clampTo: canvasBounds)
        case .idle, .settled:
            break
        }

        updateDimPath()
        updateSelectionLayers()
        updateCrosshair()
        updateLoupe()
        updateHint()

        if isRegionPickMode {
            notifySelectionChanged()
            schedulePauseSignal()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isInputArmed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            // 拖选区边缘收手：回到「已定」状态，不把它当成一次标注。
            if case .resizing = interaction {
                interaction = .settled
                return
            }
            inlineMouseUp(point)
            return
        }
        cursorPoint = point

        switch interaction {
        case .pressing:
            // 单击：命中窗口
            if let hoveredWindow {
                if isRegionPickMode {
                    selection = DisplayGeometry.localRect(
                        fromCGRect: hoveredWindow.frameInCGPoints,
                        screen: screen
                    ).intersection(canvasBounds)
                    // 先把选区视觉画出来再交付：滚动长图会把遮罩留着当取景框，
                    // 少了这一步绿框就不会出现。
                    updateAllLayers()
                    interaction = .settled
                    Self.rememberedSelection[snapshot.displayID] = selection
                    notifySelectionChanged()
                    firePauseSignal()
                } else {
                    onWindowSelected?(hoveredWindow)
                }
                return
            }
            interaction = .idle
        case .selecting:
            if let rect = selection,
                rect.width >= Theme.minimumSelectionSize,
                rect.height >= Theme.minimumSelectionSize
            {
                interaction = .settled
            } else {
                selection = nil
                interaction = .idle
            }
        case .resizing, .moving:
            interaction = .settled
        case .idle, .settled:
            break
        }

        // 原地模式：鼠标一松开（拖拽结束）就弹出标注工具栏。
        if inlineMode, isSettled, phase == .selecting, selection != nil {
            enterAnnotating()
            return
        }

        // 滚动长图：松手也立刻把「手动 / 自动」浮出来（不用等鼠标停住，
        // 更不用按 ↵）；在点模式之前选区还能继续拖 / 缩放。
        if isRegionPickMode {
            if isSettled, let selection {
                Self.rememberedSelection[snapshot.displayID] = selection
                notifySelectionChanged()
                firePauseSignal()
            } else {
                cancelPauseSignal()
                notifySelectionChanged()
            }
            updateAllLayers()
            updateHoveredWindow(at: point)
            updateWindowHighlight()
            return
        }

        if isSettled, let selection {
            Self.rememberedSelection[snapshot.displayID] = selection
        }
        updateAllLayers()
        updateHoveredWindow(at: point)
        updateWindowHighlight()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInputArmed else { return }
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        guard isInputArmed else { return }
        if phase == .annotating {
            switch event.keyCode {
            case 53: // Esc：直接退出整个截图
                onCancel?()
            case 36, 76: // Return
                confirmInline()
            case 51, 117: // Delete
                inlineUndo()
            default:
                super.keyDown(with: event)
            }
            return
        }
        switch event.keyCode {
        case 53: // kVK_Escape
            onCancel?()
        case 36, 76: // Return / keypad Enter
            // 滚动长图：↵ 只当「我选好了」，浮出模式条；真正的开始交给手动 / 自动。
            if isRegionPickMode {
                firePauseSignal()
            } else {
                commit()
            }
        case 48: // Tab
            restoreRememberedSelection()
        case 49: // Space: 在自由框选与窗口截取模式之间切换
            if selection == nil && !isRegionPickMode {
                isWindowOnlyMode.toggle()
            }
        case 123, 124, 125, 126: // 方向键
            nudge(keyCode: event.keyCode, large: event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Inline annotation

    /// 选区定下来后进入原地标注：工具栏出现在选框下方，直接在冻结画面上标注。
    private func enterAnnotating() {
        guard inlineMode, let selection, selection.width > 1, selection.height > 1 else { return }
        phase = .annotating
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        eraserStrokes.removeAll()
        annotationDraft = nil
        selectedID = nil
        inlineEditingTextID = nil
        interaction = .settled
        onInlineEditingChanged?(true)

        // 选区绿框与控制点**继续留在画面上**：工具栏弹出后，拖着边缘还能改区域。
        updateSelectionLayers()
        windowHighlightLayer.isHidden = true
        crosshairLayer.path = nil

        preparePreviewBase()
        updateLiveTextOverlay()
        // 进入时就只弹工具栏，不显示任何标注层，避免画面「跳」一下。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        annotationLayer.contents = nil
        annotationLayer.isHidden = true
        CATransaction.commit()
        showToolbar()
    }

    private func exitAnnotating() {
        hideToolbar()
        liveTextHost?.removeFromSuperview()
        liveTextHost = nil
        cropImage = nil
        textField?.removeFromSuperview()
        textField = nil
        annotations.removeAll()
        eraserStrokes.removeAll()
        annotationDraft = nil
        selectedID = nil
        inlineEditingTextID = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        annotationLayer.contents = nil
        annotationLayer.isHidden = true
        inlineSelectionBorderLayer.isHidden = true
        inlineHandlesLayer.isHidden = true
        CATransaction.commit()
        phase = .selecting
        onInlineEditingChanged?(false)
        updateAllLayers()
    }

    /// 标注态里拖动选区边缘：改选区的同时，把标注 / 橡皮笔迹按**新原点**平移，
    /// 让它们继续钉在画面的同一处（否则会跟着框一起跑）。
    private func applyRegionResize(from previous: CGRect, to updated: CGRect) {
        guard updated != previous else { return }

        // 选区原点在屏幕坐标里的位移 → 图像坐标里的反向位移：
        // 左 / 上边缘往外扩，同一画面内容在图像里的坐标就变大。
        let delta = SelectionGeometry.imageDelta(
            from: previous,
            to: updated,
            scale: snapshot.effectiveScale
        )
        if delta != .zero {
            annotations = annotations.map { $0.translated(by: delta) }
            eraserStrokes = eraserStrokes.map { stroke in
                EraserStroke(
                    points: stroke.points.map {
                        CGPoint(x: $0.x + delta.width, y: $0.y + delta.height)
                    },
                    radius: stroke.radius
                )
            }
            if let draft = annotationDraft {
                annotationDraft = draft.translated(by: delta)
            }
        }

        selection = updated
        // 底图换了一块，预览底图 / 标注层 / 选区视觉 / 工具栏位置都要跟着更新。
        preparePreviewBase()
        updateDimPath()
        updateSelectionLayers()
        updateAnnotationLayer()
        updateInlineSelectionLayers()
        layoutToolbars()
    }

    private func cancelInline() {
        exitAnnotating()
        selection = nil
        interaction = .idle
        updateAllLayers()
    }

    /// 当前「已烘焙标注」的成图（用于下载 / 钉图）。
    private func currentAnnotatedImage() -> CGImage? {
        commitPendingInlineText()
        guard let selection, let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) else {
            return nil
        }
        return compose(base: crop, annotations: annotations, strokes: eraserStrokes) ?? crop
    }

    private func confirmInline() {
        guard let selection, let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) else {
            cancelInline()
            return
        }
        commitPendingInlineText()
        let final = compose(base: crop, annotations: annotations, strokes: eraserStrokes) ?? crop
        let rect = selection
        exitAnnotating()
        onCommitAnnotated?(final, rect)
    }

    private func preparePreviewBase() {
        guard let selection, let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) else {
            previewBase = nil
            previewScale = 1
            return
        }
        cropImage = crop
        let longest = max(crop.width, crop.height)
        previewScale = longest > 1600 ? 1600 / CGFloat(longest) : 1
        previewBase = Self.rasterize(crop, scale: previewScale)
    }

    private static func rasterize(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func updateAnnotationLayer() {
        toolbarModel?.canUndo = !undoStack.isEmpty
        toolbarModel?.canRedo = !redoStack.isEmpty

        // 草稿要「有实际尺寸」才画；单击产生的零尺寸草稿不显示，避免闪一下。
        var list = annotations
        if let annotationDraft, isMeaningfulDraft(annotationDraft) {
            list.append(annotationDraft)
        }

        let scaledStrokes = eraserStrokes.map {
            EraserStroke(
                points: $0.points.map { CGPoint(x: $0.x * previewScale, y: $0.y * previewScale) },
                radius: $0.radius * previewScale
            )
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard let previewBase, let selection, !list.isEmpty else {
            annotationLayer.contents = nil
            annotationLayer.isHidden = true
            CATransaction.commit()
            return
        }
        let scaled = list.map { $0.scaled(by: previewScale) }
        let image = compose(base: previewBase, annotations: scaled, strokes: scaledStrokes)
            ?? previewBase
        annotationLayer.frame = selection
        annotationLayer.contents = image
        annotationLayer.isHidden = false
        CATransaction.commit()
    }

    /// 依次绘制标注，再用「清空」混合模式沿橡皮笔迹擦出透明区域。
    private func compose(
        base: CGImage,
        annotations: [Annotation],
        strokes: [EraserStroke]
    ) -> CGImage? {
        guard let annotated = AnnotationRenderer.render(base: base, annotations: annotations)
        else { return nil }
        guard !strokes.isEmpty else { return annotated }

        let width = annotated.width
        let height = annotated.height
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return annotated }
        context.draw(annotated, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.clear)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            context.setLineWidth(max(2, stroke.radius * 2))
            let points = stroke.points.map {
                CGPoint(x: $0.x, y: CGFloat(height) - $0.y)
            }
            guard let first = points.first else { continue }
            context.beginPath()
            context.move(to: first)
            if points.count == 1 {
                context.addLine(to: first)
            } else {
                for point in points.dropFirst() { context.addLine(to: point) }
            }
            context.strokePath()
        }
        return context.makeImage()
    }

    /// 草稿是否已经「成形」（用于避免单击时的零尺寸闪烁）。
    private func isMeaningfulDraft(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .pixelate(let rect, _),
            .blur(let rect, _):
            return rect.width >= 1.5 || rect.height >= 1.5
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 2
        case .line(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= 2
        case .pen(let points):
            return points.count >= 2
        case .counter, .callout:
            return true
        case .text:
            return false
        }
    }

    private func pushUndo() {
        undoStack.append(
            Snapshot(annotations: annotations, strokes: eraserStrokes, selection: selection)
        )
        redoStack.removeAll()
    }

    private func inlineUndo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(
            Snapshot(annotations: annotations, strokes: eraserStrokes, selection: selection)
        )
        apply(previous)
    }

    private func inlineRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(
            Snapshot(annotations: annotations, strokes: eraserStrokes, selection: selection)
        )
        apply(next)
    }

    private func apply(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        eraserStrokes = snapshot.strokes

        let selectionChanged = snapshot.selection != selection
        selection = snapshot.selection
        if selectionChanged {
            preparePreviewBase()
            updateDimPath()
            updateSelectionLayers()
            layoutToolbars()
        }

        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }

    // MARK: Inline selection / editing

    private var selectedAnnotation: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    private func updateAnnotation(_ id: UUID, _ transform: (Annotation) -> Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index] = transform(annotations[index])
    }

    /// 选中态的控制点（crop 像素坐标）。
    private func inlineHandles(for annotation: Annotation) -> [(ShapeHandle, CGPoint)] {
        var handles: [(ShapeHandle, CGPoint)] = []
        if abs(annotation.rotation) < 0.001 {
            switch annotation.kind {
            case .rectangle, .ellipse, .highlight, .pixelate, .pen, .text:
                handles.append(contentsOf: ShapeGeometry.resizeHandles(for: annotation))
            default:
                break
            }
        }
        switch annotation.kind {
        case .arrow(let from, let to, let control):
            handles.append((.arrowStart, from))
            handles.append((.arrowEnd, to))
            handles.append(
                (.arrowControl, control ?? CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2))
            )
        case .counter(let center, _, let leader):
            handles.append(
                (.counterLeader, leader ?? CGPoint(x: center.x + 48, y: center.y - 48))
            )
        default:
            break
        }
        handles.append((.rotate, ShapeGeometry.rotateHandle(for: annotation, distance: 28)))
        return handles
    }

    private func updateInlineSelectionLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard phase == .annotating, let selected = selectedAnnotation else {
            inlineSelectionBorderLayer.isHidden = true
            inlineHandlesLayer.isHidden = true
            inlineSelectionBorderLayer.path = nil
            inlineHandlesLayer.path = nil
            return
        }

        let corners = selected.rotatedCorners().map { viewPoint($0) }
        let border = CGMutablePath()
        border.addLines(between: corners)
        border.closeSubpath()
        inlineSelectionBorderLayer.path = border
        inlineSelectionBorderLayer.isHidden = false

        let path = CGMutablePath()
        let radius = Self.inlineHandleRadius
        for (_, point) in inlineHandles(for: selected) {
            let center = viewPoint(point)
            path.addEllipse(
                in: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        }
        inlineHandlesLayer.path = path
        inlineHandlesLayer.isHidden = false
    }

    private static let inlineHandleRadius: CGFloat = 4.5

    private func inlineHitHandle(_ annotation: Annotation, at cropPoint: CGPoint) -> ShapeHandle? {
        let tolerance = 11 * snapshot.effectiveScale
        var best: (ShapeHandle, CGFloat)?
        for (handle, point) in inlineHandles(for: annotation) {
            let distance = Annotation.distance(cropPoint, point)
            if distance <= tolerance, best == nil || distance < best!.1 {
                best = (handle, distance)
            }
        }
        return best?.0
    }

    private func inlineAnnotation(at cropPoint: CGPoint) -> Annotation? {
        let tolerance = max(6, 8 * snapshot.effectiveScale)
        return annotations.last { $0.contains(cropPoint, tolerance: tolerance) }
    }

    private func textOrigin(of annotation: Annotation) -> CGPoint {
        if case .text(let origin, _, _) = annotation.kind { return origin }
        return annotation.center
    }

    // MARK: Inline toolbar

    private func showToolbar() {
        let seed = annotationDefaults.sanitized
        let model = InlineToolbarModel()
        model.tool = seed.tool == .crop ? .rectangle : seed.tool
        model.color = seed.color
        model.lineWidth = seed.lineWidth
        model.eraserSize = seed.eraserSize
        model.mosaicBlock = seed.mosaicBlock
        model.blurRadius = seed.blurRadius
        model.onConfirm = { [weak self] in self?.confirmInline() }
        model.onCancel = { [weak self] in self?.onCancel?() }
        model.onUndo = { [weak self] in self?.inlineUndo() }
        model.onRedo = { [weak self] in self?.inlineRedo() }
        model.onSave = { [weak self] in
            guard let self, let image = self.currentAnnotatedImage() else { return }
            self.onSaveImage?(image)
        }
        model.onPin = { [weak self] in
            guard let self, let image = self.currentAnnotatedImage() else { return }
            self.onPinImage?(image, self.selection ?? .zero)
        }
        toolbarModel = model

        // 主工具栏：固定尺寸，永不重算 → 展开选项时也不闪烁。
        let main = NSHostingView(rootView: InlineMainToolbar(model: model))
        main.translatesAutoresizingMaskIntoConstraints = true
        addSubview(main)
        mainToolbarHost = main
        layoutToolbars()

        // 只在颜色/粗细开关变化时重建下方选项条。
        observeOptions(model)
        observeDefaults(model)
    }

    /// 工具 / 颜色 / 参数变化时回报，由外部落盘（下次截图沿用）。
    private func observeDefaults(_ model: InlineToolbarModel) {
        withObservationTracking {
            _ = model.tool
            _ = model.color
            _ = model.lineWidth
            _ = model.eraserSize
            _ = model.mosaicBlock
            _ = model.blurRadius
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.toolbarModel === model else { return }
                self.onAnnotationDefaultsChange?(
                    AnnotationDefaults(
                        tool: model.tool,
                        color: model.color,
                        lineWidth: model.lineWidth,
                        fontSize: self.annotationDefaults.fontSize,
                        mosaicBlock: model.mosaicBlock,
                        blurRadius: model.blurRadius,
                        eraserSize: model.eraserSize
                    )
                )
                self.observeDefaults(model)
            }
        }
    }

    private func hideToolbar() {
        mainToolbarHost?.removeFromSuperview()
        mainToolbarHost = nil
        optionsToolbarHost?.removeFromSuperview()
        optionsToolbarHost = nil
        toolbarModel = nil
    }

    /// 颜色 / 粗细开关变化时重建选项条（重新量尺寸，避免改尺寸闪烁）。
    private func observeOptions(_ model: InlineToolbarModel) {
        withObservationTracking {
            _ = model.showColor
            _ = model.showWidth
            _ = model.isLiveTextActive
            // 编辑文字时改颜色 / 粗细，输入框要跟着变（所见即所得）。
            _ = model.color
            _ = model.lineWidth
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if let field = self.textField, self.inlineEditingTextID != nil {
                    self.applyInlineTextStyle(field, model: model)
                    self.fitInlineTextField()
                }
                self.rebuildOptionsToolbar()
                self.updateLiveTextOverlay()
                if self.toolbarModel === model {
                    self.observeOptions(model)
                }
            }
        }
    }

    /// 实况文本：选中「选择」工具时铺一层可拖选复制文字的覆盖层。
    private func updateLiveTextOverlay() {
        let wantsLiveText = (toolbarModel?.isLiveTextActive ?? false) && cropImage != nil && selection != nil
        if wantsLiveText {
            if liveTextHost == nil, let image = cropImage {
                let host = NSHostingView(rootView: LiveTextOverlay(image: image))
                host.translatesAutoresizingMaskIntoConstraints = true
                addSubview(host)
                liveTextHost = host
            }
            if let host = liveTextHost, let selection {
                host.frame = selection
            }
        } else {
            liveTextHost?.removeFromSuperview()
            liveTextHost = nil
        }
    }

    private func rebuildOptionsToolbar() {
        optionsToolbarHost?.removeFromSuperview()
        optionsToolbarHost = nil

        guard let model = toolbarModel, model.showColor || model.showWidth else { return }
        let host = NSHostingView(rootView: InlineOptionsToolbar(model: model))
        host.translatesAutoresizingMaskIntoConstraints = true
        addSubview(host)
        optionsToolbarHost = host
        layoutToolbars()
    }

    private func layoutToolbars() {
        guard let selection, let main = mainToolbarHost else { return }
        main.layoutSubtreeIfNeeded()
        let mainSize = main.fittingSize
        var origin = CGPoint(
            x: selection.midX - mainSize.width / 2,
            y: selection.minY - mainSize.height - 10
        )
        if origin.y < bounds.minY + 8 {
            origin.y = selection.maxY + 10
        }
        origin.x = min(
            max(origin.x, bounds.minX + 8),
            max(bounds.minX + 8, bounds.maxX - mainSize.width - 8)
        )
        origin.y = min(origin.y, bounds.maxY - mainSize.height - 8)
        main.frame = CGRect(origin: origin, size: mainSize)

        guard let options = optionsToolbarHost else { return }
        options.layoutSubtreeIfNeeded()
        let size = options.fittingSize
        // 居中到**刚才点的那个按钮**下方（按钮的 midX 由 SwiftUI 上报）。
        let anchorX = main.frame.minX + (toolbarModel?.optionsAnchorX ?? mainSize.width)
        let x = min(
            max(anchorX - size.width / 2, bounds.minX + 8),
            max(bounds.minX + 8, bounds.maxX - size.width - 8)
        )
        options.frame = CGRect(
            x: x,
            y: main.frame.minY - 8 - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: Eraser (see compose)

    // MARK: Inline geometry    // MARK: Inline geometry

    /// 视图坐标（原点左下）→ 选区裁剪后的图像像素坐标（原点左上）。
    private func annotationPoint(from point: CGPoint) -> CGPoint {
        guard let selection else { return .zero }
        let scale = snapshot.effectiveScale
        return CGPoint(
            x: (point.x - selection.minX) * scale,
            y: (selection.maxY - point.y) * scale
        )
    }

    private func viewPoint(fromAnnotation point: CGPoint) -> CGPoint {
        guard let selection else { return .zero }
        let scale = snapshot.effectiveScale
        return CGPoint(x: selection.minX + point.x / scale, y: selection.maxY - point.y / scale)
    }

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        viewPoint(fromAnnotation: point)
    }

    private func makeInlineDraft(start: CGPoint, current: CGPoint) -> Annotation? {
        guard let model = toolbarModel else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
        switch model.tool {
        case .rectangle: return Annotation(kind: .rectangle(rect), color: model.color, lineWidth: model.lineWidth)
        case .ellipse: return Annotation(kind: .ellipse(rect), color: model.color, lineWidth: model.lineWidth)
        case .highlight: return Annotation(kind: .highlight(rect), color: model.color, lineWidth: model.lineWidth)
        case .pixelate: return Annotation(kind: .pixelate(rect, block: model.mosaicBlock), color: model.color, lineWidth: model.lineWidth)
        case .blur: return Annotation(kind: .blur(rect, radius: model.blurRadius), color: model.color, lineWidth: model.lineWidth)
        case .arrow: return Annotation(kind: .arrow(from: start, to: current, control: nil), color: model.color, lineWidth: model.lineWidth)
        case .line: return Annotation(kind: .line(from: start, to: current), color: model.color, lineWidth: model.lineWidth)
        case .pen: return Annotation(kind: .pen(points: [start, current]), color: model.color, lineWidth: model.lineWidth)
        case .counter:
            return Annotation(
                kind: .counter(center: start, value: inlineCounterValue, leader: nil),
                color: model.color,
                lineWidth: model.lineWidth
            )
        // 裁剪只在标注编辑器窗口里提供，原地编辑不参与。
        case .text, .select, .eraser, .crop: return nil
        }
    }

    private func isValidInlineDraft(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .pixelate(let rect, _),
            .blur(let rect, _):
            return rect.width >= 3 && rect.height >= 3
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 3
        case .line(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= 3
        case .counter, .callout, .pen, .text:
            return true
        }
    }

    /// 统一的原地鼠标处理：先命中已有对象（任意工具下都可编辑），空白处才新建。
    private func inlineMouseDown(_ point: CGPoint, clickCount: Int) {
        // 点别处一律先把正在编辑的文字落地。
        commitPendingInlineText()
        let crop = annotationPoint(from: point)
        let tool = toolbarModel?.tool ?? .rectangle

        // 橡皮：画笔式擦除（擦到的地方露出底层）。
        if tool == .eraser {
            commitPendingInlineText()
            pushUndo()
            erasing = true
            lastErasePoint = crop
            let radius = max(3, (toolbarModel?.eraserSize ?? 28) / 2 * snapshot.effectiveScale)
            eraserStrokes.append(EraserStroke(points: [crop], radius: radius))
            updateAnnotationLayer()
            return
        }

        // 1) 选中对象 + 命中控制点 → 缩放 / 旋转 / 端点
        if let selected = selectedAnnotation,
            let handle = inlineHitHandle(selected, at: crop)
        {
            pushUndo()
            switch handle {
            case .rotate:
                let angle = atan2(crop.y - selected.center.y, crop.x - selected.center.x)
                inlineEditDrag = .rotating(id: selected.id, startAngle: angle, original: selected)
            case .arrowStart, .arrowEnd, .arrowControl, .counterLeader:
                inlineEditDrag = .endpoint(id: selected.id, handle: handle, original: selected)
            default:
                inlineEditDrag = .resizing(id: selected.id, handle: handle, original: selected)
            }
            return
        }

        // 2) 命中已有标注 → 选中并移动（不区分当前工具，和编辑窗口一致）
        if let hit = inlineAnnotation(at: crop) {
            selectedID = hit.id
            if clickCount >= 2, case .text = hit.kind {
                beginInlineText(at: textOrigin(of: hit), editing: hit)
                inlineEditDrag = .none
                updateInlineSelectionLayers()
                return
            }
            pushUndo()
            inlineEditDrag = .moving(id: hit.id, start: crop, original: hit)
            updateInlineSelectionLayers()
            return
        }

        // 3) 空白：清空选中；若当前是绘制工具则开始新标注
        selectedID = nil
        inlineEditDrag = .none
        updateInlineSelectionLayers()
        guard tool.isDrawing else { return }

        commitPendingInlineText()
        inlineStart = crop
        inlineDragging = true
        annotationDraft = makeInlineDraft(start: crop, current: crop)
        updateAnnotationLayer()
    }

    private func inlineMouseDragged(_ point: CGPoint) {
        let crop = annotationPoint(from: point)

        if erasing {
            if var stroke = eraserStrokes.last {
                stroke.points.append(crop)
                eraserStrokes[eraserStrokes.count - 1] = stroke
            }
            lastErasePoint = crop
            updateAnnotationLayer()
            return
        }

        if inlineDragging, let model = toolbarModel {
            if model.tool == .pen, case .pen(var points) = annotationDraft?.kind {
                points.append(crop)
                annotationDraft?.kind = .pen(points: points)
            } else {
                annotationDraft = makeInlineDraft(start: inlineStart, current: crop)
            }
            updateAnnotationLayer()
            return
        }

        switch inlineEditDrag {
        case .none:
            break
        case .moving(let id, let start, let original):
            let delta = CGSize(width: crop.x - start.x, height: crop.y - start.y)
            updateAnnotation(id) { _ in original.translated(by: delta) }
        case .resizing(let id, let handle, let original):
            updateAnnotation(id) { _ in
                original.resized(handle: handle, to: crop, lockAspect: false)
            }
        case .rotating(let id, let startAngle, let original):
            let angle = atan2(crop.y - original.center.y, crop.x - original.center.x)
            updateAnnotation(id) { _ in original.rotated(by: angle - startAngle) }
        case .endpoint(let id, let handle, let original):
            updateAnnotation(id) { _ in original.withEndpoint(handle, to: crop) }
        }
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }

    private func inlineMouseUp(_ point: CGPoint) {
        if erasing {
            erasing = false
            lastErasePoint = nil
            return
        }

        if inlineDragging, let model = toolbarModel {
            inlineDragging = false
            if model.tool == .text {
                annotationDraft = nil
                updateAnnotationLayer()
                beginInlineText(at: inlineStart)
                return
            }
            if let draft = annotationDraft, isValidInlineDraft(draft) {
                pushUndo()
                annotations.append(draft)
                selectedID = draft.id
                if case .counter = draft.kind { inlineCounterValue += 1 }
            }
            annotationDraft = nil
            updateAnnotationLayer()
            updateInlineSelectionLayers()
            return
        }

        if case .none = inlineEditDrag { return }
        inlineEditDrag = .none
        updateInlineSelectionLayers()
    }

    // MARK: Inline text field

    private var inlineTextOrigin: CGPoint = .zero
    private var inlineCounterValue = 1

    /// 就地输入文字：**直接落在点击位置**，按最终的字号与颜色显示（所见即所得），
    /// 不弹任何面板、不铺底色，只有一圈很细的同色边框标出编辑框。
    private func beginInlineText(at cropPoint: CGPoint, editing: Annotation? = nil) {
        guard let model = toolbarModel else { return }
        commitPendingInlineText()
        inlineTextOrigin = cropPoint
        inlineEditingTextID = editing?.id

        let existing: String
        if case .text(_, let string, _)? = editing?.kind {
            existing = string
        } else {
            existing = ""
        }

        let field = NSTextField(frame: .zero)
        field.stringValue = existing
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.alignment = .left
        field.wantsLayer = true
        field.target = self
        field.action = #selector(handleInlineTextCommit)
        applyInlineTextStyle(field, model: model)
        addSubview(field)
        textField = field
        fitInlineTextField()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inlineTextDidChange),
            name: NSControl.textDidChangeNotification,
            object: field
        )
        window?.makeFirstResponder(field)
    }

    /// 写入标注的字号（图像像素）：与提交时用的同一条公式。
    private static func inlineTextFontSize(lineWidth: CGFloat) -> CGFloat {
        max(12, lineWidth * 6)
    }

    /// 字号 / 颜色都跟最终渲染一致（Helvetica + 标注色），这才是「所见即所得」。
    private func applyInlineTextStyle(_ field: NSTextField, model: InlineToolbarModel) {
        let scale = max(1, snapshot.effectiveScale)
        let pointSize = Self.inlineTextFontSize(lineWidth: model.lineWidth) / scale
        field.font = NSFont(name: "Helvetica", size: pointSize)
            ?? NSFont.systemFont(ofSize: pointSize)
        let color = NSColor(cgColor: model.color.cgColor) ?? .labelColor
        field.textColor = color
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 2
        field.layer?.borderColor = color.withAlphaComponent(0.45).cgColor
        field.frame.origin = inlineTextFieldOrigin(pointSize: pointSize)
    }

    /// 编辑框左上角对齐点击位置（AppKit 坐标 y 向上）。
    private func inlineTextFieldOrigin(pointSize: CGFloat) -> CGPoint {
        let view = viewPoint(fromAnnotation: inlineTextOrigin)
        return CGPoint(x: view.x, y: view.y - pointSize * 1.4)
    }

    /// 框贴着文字宽度：不然它会吞掉旁边的点击。
    private func fitInlineTextField() {
        guard let field = textField, let font = field.font else { return }
        let textWidth = (field.stringValue as NSString)
            .size(withAttributes: [.font: font]).width
        field.frame = CGRect(
            x: field.frame.origin.x,
            y: field.frame.origin.y,
            width: max(18, textWidth + 8),
            height: font.pointSize * 1.4
        )
    }

    @objc private func inlineTextDidChange() {
        fitInlineTextField()
    }

    @objc private func handleInlineTextCommit() {
        commitPendingInlineText()
    }

    private func commitPendingInlineText() {
        guard let field = textField, let model = toolbarModel else { return }
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = inlineTextOrigin
        let editingID = inlineEditingTextID
        NotificationCenter.default.removeObserver(
            self, name: NSControl.textDidChangeNotification, object: field
        )
        field.removeFromSuperview()
        textField = nil
        inlineEditingTextID = nil

        guard !string.isEmpty else {
            if let editingID {
                pushUndo()
                annotations.removeAll { $0.id == editingID }
            }
            updateAnnotationLayer()
            updateInlineSelectionLayers()
            return
        }

        pushUndo()
        if let editingID, let index = annotations.firstIndex(where: { $0.id == editingID }) {
            annotations[index] = annotations[index].withText(string)
        } else {
            annotations.append(
                Annotation(
                    kind: .text(
                        origin: origin,
                        string: string,
                        fontSize: max(12, model.lineWidth * 6)
                    ),
                    color: model.color,
                    lineWidth: model.lineWidth
                )
            )
        }
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }

    // MARK: - Actions

    private func commit() {
        if phase == .annotating {
            confirmInline()
            return
        }
        guard let selection, selection.width >= 1, selection.height >= 1 else { return }
        if inlineMode {
            enterAnnotating()
            return
        }
        Self.rememberedSelection[snapshot.displayID] = selection
        onCommit?(selection)
    }

    private func restoreRememberedSelection() {
        guard let remembered = Self.rememberedSelection[snapshot.displayID] else { return }
        let rect = remembered.intersection(canvasBounds)
        guard !rect.isEmpty else { return }
        selection = rect
        interaction = .settled
        updateAllLayers()
        updateHoveredWindow(at: cursorPoint ?? .zero)
        updateWindowHighlight()
        if isRegionPickMode {
            notifySelectionChanged()
            firePauseSignal()
        }
    }

    private func nudge(keyCode: UInt16, large: Bool) {
        guard let selection else { return }
        let step: CGFloat = large ? 10 : 1
        var delta = CGSize.zero
        switch keyCode {
        case 123: delta.width = -step
        case 124: delta.width = step
        case 125: delta.height = -step
        case 126: delta.height = step
        default: return
        }
        self.selection = SelectionGeometry.moved(
            selection,
            by: delta,
            clampTo: canvasBounds
        )
        updateAllLayers()
        if isRegionPickMode {
            notifySelectionChanged()
            schedulePauseSignal()
        }
    }
}

/// 放大镜的图层几何。
///
/// 单独抽出来是为了能单测：`contentsRect` 的 y 原点在 macOS 上并不直观
/// （见 `JietuTests/ContentRectOriginTests`）——实测非 flipped 图层里
/// **y = 0 取的是图像最后一行**，所以窗口的上边距要换算成「距底边的下边距」。
///
/// @author ixxxxoooo
enum LoupeGeometry {
    /// 采样窗口（图像像素、原点左上）→ `contentsRect`。
    static func contentsRect(
        sourceOrigin: CGPoint,
        cells: Int,
        imageSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        return CGRect(
            x: sourceOrigin.x / imageSize.width,
            // 屏幕坐标是「原点左上」，而 contentsRect 的 y 是「距图像底边」——
            // 少这一次翻转，放大镜就会整体上下镜像（鼠标在空白处，镜里却全是内容）。
            y: (imageSize.height - sourceOrigin.y - CGFloat(cells)) / imageSize.height,
            width: CGFloat(cells) / imageSize.width,
            height: CGFloat(cells) / imageSize.height
        )
    }
}
