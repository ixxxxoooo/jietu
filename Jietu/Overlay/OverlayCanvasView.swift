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
    /// 录屏模式：框好（或点一下窗口）就把区域交出去开录。
    var isRecordMode = false
    var onRecordRegionPicked: ((CGRect) -> Void)?
    /// 就地编辑工具栏里选了「手动 / 自动滚动」：参数是模式与选区（本显示器 local 矩形）。
    var onScrollCapture: ((ScrollingCaptureSession.Mode, CGRect) -> Void)?
    /// 选区被拖动 / 缩放 / 清空（nil）→ 让控制条跟着选框走。
    var onSelectionChanged: ((CGRect?) -> Void)?
    /// 用户选定某个窗口（单击窗口触发）。
    var onWindowSelected: ((WindowInfo) -> Void)?

    /// 拖动中判定「停住」的时长；停住就浮出工具栏，不必等用户松手。
    private static let regionPickPauseDelay: TimeInterval = 0.35
    private var pauseWorkItem: DispatchWorkItem?

    /// 原地编辑恢复图片时，四周至少让出的空间（point）。
    ///
    /// 下方这一条正是工具栏的位置：主栏（~46）+ 间距（10）+ 二级参数栏（~46）+ 收边（8）
    /// 叠起来刚好 ~120，所以 `minY` 不低于它时两条工具栏都能摆在图片下面，不会压住图。
    private static let inlineEditorBottomInset: CGFloat = 120
    /// 上 / 左右只留一点呼吸感，够放得下就按原尺寸来。
    private static let inlineEditorEdgeInset: CGFloat = 40

    /// 裁剪框的最小边长：比它小的一拖当作「没拖」（单击误触），不参与裁剪。
    private static let minimumCropSide: CGFloat = 10

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
    /// 原地编辑时给不给「裁剪」工具。
    ///
    /// 只有「已有的图片」才给（从浮窗卡片 / 钉图 / 历史记录进来编辑的）；刚截下来的那块画面不给——
    /// 它本来就是用户刚框出来的，再裁一次容易让人以为是在重新框选区。
    var allowsCrop = false
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
    /// 撤销 / 重做的快捷键（设置页配，默认 ⌘Z / ⇧⌘Z）。
    var editorShortcuts: EditorShortcuts = .standard

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

    private struct Snapshot {
        let annotations: [Annotation]
        let strokes: [EraserStroke]
        /// 选区也进快照：标注态里能拖边缘改区域，撤销时必须连选区一起回滚，
        /// 否则标注会按旧原点画在新选区上、整体错位。
        let selection: CGRect?
        let restoredBaseImage: CGImage?
        let restoredImageFrame: CGRect?
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var eraserStrokes: [EraserStroke] = []
    private var selectedID: UUID?
    private var hoveredAnnotationID: UUID?
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
    /// 裁剪时底图（正在裁的那张图）的外框。
    private let baseFrameBorderLayer = CAShapeLayer()
    private var annotations: [Annotation] = []
    private var annotationDraft: Annotation?
    /// 选区裁剪出来的原图。标注层按**它的原始分辨率**渲染，所以线 / 箭头不会因为缩放发虚。
    private var cropImage: CGImage?
    private var liveTextHost: NSView?
    private var toolbarModel: InlineToolbarModel?
    private var mainToolbarHost: NSView?
    private var optionsToolbarHost: NSView?
    private var textField: InlineTextField?
    private var inlineDragging = false
    private var inlineStart: CGPoint = .zero

    private let annotationLayer = CALayer()
    /// 从浮窗（钉图或快速访问）恢复时的原图。
    var restoredBaseImage: CGImage?
    private var restoredImageFrame: CGRect?
    private var cropInitialState: Snapshot?
    /// 这一轮裁剪「正在裁的那张图」的屏幕矩形（见 `cropFrame`）。
    private var cropSessionFrame: CGRect?
    private let restoredContainerLayer = CALayer()
    private let restoredImageLayer = CALayer()

    // MARK: - Layers

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let windowHighlightLayer = CAShapeLayer()
    private let selectionBorderOuterLayer = CAShapeLayer()
    private let selectionBorderInnerLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let sizeLabelLayer = PillLabelLayer()
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

    /// 从浮窗（钉图或快速访问卡片）恢复到原地编辑模式，图片在屏幕中央居中展示。
    ///
    /// 尺寸规则：**按图片在屏幕上的真实点尺寸 1:1 展示**（不放大）——窗口截图截多大、区域截图
    /// 框多大，原地编辑就多大，和刚才那张浮窗卡片 / 原窗口看起来一致；只有真实尺寸放不下时
    /// 才等比缩小，缩到「画布减去工具栏空间与边距」的可用区域内。全屏截图必然放不下，所以
    /// 只有它（以及整屏大小的窗口 / 选区）会被缩放，普通窗口截图不再被无谓地缩小。
    func restoreImageForInlineEditing(_ image: CGImage) {
        inlineMode = true
        restoredBaseImage = image

        let backingScale = window?.backingScaleFactor ?? snapshot.nominalScaleFactor
        let scaleFactor = backingScale > 0 ? backingScale : 2.0
        let naturalWidth = CGFloat(image.width) / scaleFactor
        let naturalHeight = CGFloat(image.height) / scaleFactor

        let availableWidth = max(
            Theme.minimumSelectionSize,
            canvasBounds.width - Self.inlineEditorEdgeInset * 2
        )
        let availableHeight = max(
            Theme.minimumSelectionSize,
            canvasBounds.height - Self.inlineEditorBottomInset - Self.inlineEditorEdgeInset
        )
        let scale = min(1.0, min(availableWidth / naturalWidth, availableHeight / naturalHeight))
        let displayWidth = max(Theme.minimumSelectionSize, (naturalWidth * scale).rounded())
        let displayHeight = max(Theme.minimumSelectionSize, (naturalHeight * scale).rounded())

        let originX = ((canvasBounds.width - displayWidth) / 2).rounded()
        var originY = (((canvasBounds.height - displayHeight) / 2) + 35).rounded()
        if originY < Self.inlineEditorBottomInset {
            originY = Self.inlineEditorBottomInset
        }
        if originY + displayHeight > canvasBounds.maxY - Self.inlineEditorEdgeInset {
            originY = canvasBounds.maxY - displayHeight - Self.inlineEditorEdgeInset
        }
        let sel = CGRect(x: originX, y: originY, width: displayWidth, height: displayHeight)
        self.selection = sel
        self.restoredImageFrame = sel

        enterAnnotating()
        updateAllLayers()
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

    /// 自检用：等价于点一下工具栏里的某个工具（nil = 取消选择）。
    @discardableResult
    func debugSelectTool(_ tool: AnnotationTool?) -> Bool {
        guard let model = toolbarModel else { return false }
        model.tool = tool
        return true
    }

    /// 自检用：工具栏当前实际显示的工具（第一次截图不给裁剪）。
    var debugVisibleTools: [AnnotationTool] { toolbarModel?.visibleTools ?? [] }

    /// 自检用：工具栏当前摆在哪、是不是竖排。
    var debugToolbarLayout: (main: CGRect, options: CGRect?, isVertical: Bool) {
        (
            mainToolbarHost?.frame ?? .zero,
            optionsToolbarHost.map(\.frame),
            toolbarModel?.isVerticalLayout ?? false
        )
    }

    /// 自检用：等价于点主工具栏的 ✓（确认并交付这张图）。
    func debugConfirm() { confirmInline() }

    /// 自检用：选中了哪条标注。
    var debugSelectedID: UUID? { selectedID }

    /// 自检用：某条标注当前的样子。
    func debugAnnotation(_ id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    /// 自检用：在某个视图位置插一条文字并选中它（等价于「用文字工具写了一条、单击选中」）。
    @discardableResult
    func debugInsertText(_ string: String, atViewPoint point: CGPoint) -> UUID? {
        guard selection != nil, let model = toolbarModel else { return nil }
        let annotation = Annotation(
            kind: .text(
                origin: annotationPoint(from: point),
                string: string,
                fontSize: max(12, model.fontSize * snapshot.effectiveScale)
            ),
            color: model.color,
            lineWidth: model.lineWidth,
            textHasStroke: model.textHasStroke,
            textHasCallout: model.textHasCallout
        )
        annotations.append(annotation)
        selectedID = annotation.id
        updateAnnotationLayer()
        updateInlineSelectionLayers()
        return annotation.id
    }

    /// 自检用：现在有没有正在输入的文本框。
    var debugIsEditingText: Bool { textField != nil }

    /// 自检用：当前那条文字标注（按落定顺序取最后一条）。
    var debugLastTextAnnotation: Annotation? {
        annotations.last(where: { if case .text = $0.kind { return true } else { return false } })
    }

    /// 自检用：往正在输入的文本框里打字（等价于用户敲键盘）。
    @discardableResult
    func debugTypeText(_ text: String) -> Bool {
        guard let field = textField else { return false }
        field.stringValue = text
        fitInlineTextField()
        return true
    }

    /// 自检用：等价于点文字二级菜单里的「描边 / 标注」开关（含那条「刷到选中文字」的回调）。
    func debugSetTextStyle(hasStroke: Bool, hasCallout: Bool) {
        debugSetTextStroke(hasStroke)
        debugSetTextCallout(hasCallout)
    }

    /// 自检用：等价于点一下「描边」复选框。
    func debugSetTextStroke(_ on: Bool) {
        guard let model = toolbarModel else { return }
        model.textHasStroke = on
        model.onTextStyleChange?(.stroke)
    }

    /// 自检用：等价于点一下「标注」复选框。
    func debugSetTextCallout(_ on: Bool) {
        guard let model = toolbarModel else { return }
        model.textHasCallout = on
        model.onTextStyleChange?(.callout)
    }

    /// 自检用：只改工具栏上的取值、**不**触发回调。
    ///
    /// 用来模拟「工具栏当前值 ≠ 选中那条文字上的值」这种状态，验证别的东西变化时不会去覆盖它。
    func debugSetTextStyleWithoutApplying(hasStroke: Bool, hasCallout: Bool) {
        toolbarModel?.textHasStroke = hasStroke
        toolbarModel?.textHasCallout = hasCallout
    }

    /// 自检用：等价于点「保存 / 钉图」时交出去的那张图。
    func debugAnnotatedImage() -> CGImage? { currentAnnotatedImage() }

    /// 自检用：当前底图与它在屏幕上的 frame。
    var debugRestoredBase: (image: CGImage?, frame: CGRect?) {
        (restoredBaseImage, restoredImageFrame)
    }

    /// 自检用：底图容器与底图图层在容器里的 frame。
    ///
    /// 裁剪框悬着（还没确认）时，底图必须**整张**画着：容器 = 底图 frame、图层 = 原点起满铺。
    /// 要是容器收到裁剪框上，框外就会露出冻结屏幕，看着像在屏幕上重新框选区。
    var debugRestoredLayerFrames: (container: CGRect, image: CGRect) {
        (restoredContainerLayer.frame, restoredImageLayer.frame)
    }

    /// 自检用：压暗层当前挖的洞（裁剪时应当是整张图，不是裁剪框）。
    var debugDimHole: CGRect? { dimHoleRect }

    /// 自检用：底图外框是不是画着、画在哪。
    var debugBaseFrameBorder: (isHidden: Bool, rect: CGRect?) {
        (
            baseFrameBorderLayer.isHidden,
            baseFrameBorderLayer.path.map { $0.boundingBoxOfPath }
        )
    }

    /// 自检用：编辑用的边框 / 控制点是否压在压暗层**之上**。
    ///
    /// 压在下面的话，贴边那一条会被遮罩切掉一半，看着像「被遮罩遮住的选框」。
    var debugChromeAboveDim: Bool {
        guard let sublayers = layer?.sublayers,
            let dimIndex = sublayers.firstIndex(where: { $0 === dimLayer }),
            let borderIndex = sublayers.firstIndex(where: { $0 === inlineSelectionBorderLayer }),
            let handlesIndex = sublayers.firstIndex(where: { $0 === inlineHandlesLayer })
        else { return false }
        return borderIndex > dimIndex && handlesIndex > dimIndex
    }

    /// 自检用：标注层的 frame。裁剪 / 缩放时它必须贴**底图**，不能跟着裁剪框缩。
    var debugAnnotationLayerFrame: CGRect { annotationLayer.frame }

    /// 自检用：当前标注数量（画几条验对齐用）。
    var debugAnnotationCount: Int { annotations.count }

    /// 自检用：当前预览底图的像素尺寸。
    var debugCropImageSize: CGSize? {
        cropImage.map { CGSize(width: $0.width, height: $0.height) }
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

    /// 自检用：吸附预览（窗口描边 + 窗口标签）当前是不是真的画着。
    var debugWindowHighlightVisible: Bool {
        !windowHighlightLayer.isHidden || !windowLabelLayer.isHidden
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

        restoredContainerLayer.masksToBounds = true
        restoredContainerLayer.isHidden = true
        restoredContainerLayer.actions = [
            "frame": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull(),
        ]
        root.addSublayer(restoredContainerLayer)

        restoredImageLayer.contentsGravity = .resize
        restoredImageLayer.contentsScale = scale
        restoredImageLayer.magnificationFilter = .trilinear
        restoredImageLayer.minificationFilter = .trilinear
        restoredImageLayer.actions = [
            "contents": NSNull(),
            "frame": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull(),
            "opacity": NSNull(),
        ]
        restoredContainerLayer.addSublayer(restoredImageLayer)

        // 原地标注层：叠在冻结图之上、压暗层之下（选区被挖空，所以标注可见）。
        // 它是**原图分辨率**的（见 `updateAnnotationLayer`），正常情况下 1:1 落在屏幕上；
        // 用平滑采样而不是 nearest：选区的原点常常带小数，nearest 会把这种亚像素错位
        // 放大成肉眼可见的锯齿（线、箭头最先中招）。
        annotationLayer.frame = bounds
        annotationLayer.contentsGravity = .resize
        annotationLayer.magnificationFilter = .trilinear
        annotationLayer.minificationFilter = .trilinear
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

        // 压暗层：挖洞之外的部分压暗。放在标注层之上（框外的标注也要跟着压暗）、
        // 编辑用的边框与控制点之下（它们压着遮罩才看得清，否则贴边那一条会被切掉一半）。
        dimLayer.fillColor = NSColor.black
            .withAlphaComponent(Theme.overlayDimAlpha).cgColor
        dimLayer.fillRule = .evenOdd
        dimLayer.frame = bounds
        root.addSublayer(dimLayer)

        // 裁剪时「正在裁的那张图」的外框：裁剪框缩到图中间以后，靠它才能看清图到哪儿为止。
        baseFrameBorderLayer.fillColor = nil
        baseFrameBorderLayer.strokeColor = NSColor.white.withAlphaComponent(0.65).cgColor
        baseFrameBorderLayer.lineWidth = 1.5
        baseFrameBorderLayer.isHidden = true
        root.addSublayer(baseFrameBorderLayer)

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

        // 吸附预览（自动识别窗口边界）：**只描边、不填色**。
        // 之前压了一层 6% 的绿：窗口一大（满屏窗口）整块屏幕都跟着泛绿。
        windowHighlightLayer.fillColor = nil
        windowHighlightLayer.strokeColor = NSColor(Theme.selectionGreen).cgColor
        windowHighlightLayer.lineWidth = 3
        windowHighlightLayer.isHidden = true
        windowHighlightLayer.frame = bounds
        root.addSublayer(windowHighlightLayer)

        // 绿色选框（粗体虚线）。
        configureBorderLayer(selectionBorderOuterLayer, color: NSColor(Theme.selectionGreen))
        selectionBorderOuterLayer.lineWidth = Theme.selectionBorderWidth
        selectionBorderOuterLayer.lineDashPattern = [6, 4]
        configureBorderLayer(selectionBorderInnerLayer, color: .clear)
        root.addSublayer(selectionBorderOuterLayer)
        root.addSublayer(selectionBorderInnerLayer)

        handlesLayer.fillColor = NSColor(Theme.selectionGreen).cgColor
        handlesLayer.strokeColor = NSColor.white.cgColor
        handlesLayer.lineWidth = 1.5
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


        sizeLabelLayer.contentsScale = scale
        sizeLabelLayer.isHidden = true
        root.addSublayer(sizeLabelLayer)

        for textLayer in [windowLabelLayer, hintLayer] {
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
        // 从就地编辑进来的：工具栏 / 实况文本 / 进行中的文字框都得收掉——
        // 取景框期间遮罩是鼠标穿透的，留着它们既点不到，也只是挡着下面真实页面。
        if on {
            hideToolbar()
            liveTextHost?.isHidden = true
            textField?.isHidden = true
        }
        updateLoupe()
        CATransaction.commit()
    }

    // MARK: - Rendering

    private func updateAllLayers() {
        updateDimPath()
        updateRestoredImageLayer()
        updateSelectionLayers()
        updateCrosshair()
        updateLoupe()
        updateHint()
    }

    private func updateRestoredImageLayer() {
        guard let restoredBaseImage, let selection else {
            restoredContainerLayer.isHidden = true
            restoredImageLayer.contents = nil
            return
        }
        // 底图**整张**画在它自己的 frame 上，不跟着裁剪框裁。
        //
        // 裁剪框只标记「将要保留哪一块」，框外交给压暗层压暗就够了。要是把框外裁掉，
        // 露出来的是下面那张冻结屏幕（压暗 α 只有 0.45，还看得清），看着就成了
        // 「在屏幕上重新框一块区域」，而不是「在这张图上裁」。
        let baseFrame = restoredImageFrame ?? selection
        restoredContainerLayer.frame = baseFrame
        restoredContainerLayer.isHidden = false
        restoredImageLayer.frame = CGRect(origin: .zero, size: baseFrame.size)
        restoredImageLayer.contents = restoredBaseImage
    }

    private func updateDimPath() {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole = dimHoleRect {
            // even-odd 挖洞：洞口用圆角只在「还没定选区、只是吸附到窗口」那一种情况下，
            // 让用户先看到清晰明亮的将截窗口内容。
            path.addPath(
                dimHoleIsRoundedWindow
                    ? CGPath(roundedRect: hole, cornerWidth: 10, cornerHeight: 10, transform: nil)
                    : CGPath(rect: hole, transform: nil)
            )
        }
        dimLayer.path = path
    }

    /// 压暗层挖的洞。**裁剪时是整张图**（不是裁剪框）：框只标记「要保留哪一块」，图本身一直亮着，
    /// 免得框一缩小、框外就压暗露出底下的冻结屏幕，分不清图到哪儿为止；其余时候是选区 / 吸附到的窗口。
    private var dimHoleRect: CGRect? {
        if let cropFrame { return cropFrame }
        if let selection { return selection }
        return hoveredWindowLocalRect
    }

    /// 洞口是不是那种「还没定选区、只是吸附到了窗口」的圆角预览。
    private var dimHoleIsRoundedWindow: Bool {
        cropFrame == nil && selection == nil && hoveredWindowLocalRect != nil
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

    /// 鼠标按下之后的这段时间，吸附预览（描边 + 窗口标签）要**当场收掉**。
    ///
    /// 用户按下就是要开始操作了，视觉焦点得跟到鼠标开始操作的地方去；
    /// 不然拖框拖到一半，那个绿圈还赖在原来的窗口上（用户报的就是这个）。
    /// 只收**画面**：`hoveredWindow` 状态留着，单击命中窗口那条路还要用它。
    private var isPressPreviewSuppressed: Bool {
        switch interaction {
        case .idle, .settled:
            return false
        case .pressing, .selecting, .resizing, .moving:
            return true
        }
    }

    /// 吸附预览该画的窗口矩形。
    ///
    /// 与 `hoveredWindowLocalRect` 的区别只有一条：按下之后收起。
    /// 压暗层的洞口（`updateDimPath`）仍然按 `hoveredWindowLocalRect` 算——
    /// 按下瞬间就把窗口重新压暗会闪一下，那一片该一直亮到选区接管为止。
    private var hoveredWindowPreviewRect: CGRect? {
        isPressPreviewSuppressed ? nil : hoveredWindowLocalRect
    }

    private func updateSelectionLayers() {
        updateCropFrameBorder()
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

    /// 裁剪时给底图画一条外框：框缩到图中间以后，这条边框就是「图到哪儿为止」的参照。
    ///
    /// 只在裁剪中、且裁剪框确实比图小时才画——框和图的边界重合时再画一条纯属重复。
    private func updateCropFrameBorder() {
        guard let cropFrame else {
            baseFrameBorderLayer.isHidden = true
            baseFrameBorderLayer.path = nil
            return
        }
        let isRedundant = selection.map { $0 == cropFrame } ?? true
        baseFrameBorderLayer.isHidden = isRedundant
        baseFrameBorderLayer.path = isRedundant ? nil : CGPath(rect: cropFrame, transform: nil)
    }

    private func updateSizeLabel(_ selection: CGRect) {
        guard !isScrollCaptureChrome else { return }
        let pixelSize: CGSize
        if let restored = restoredBaseImage, let baseFrame = restoredImageFrame, baseFrame.width > 0, baseFrame.height > 0 {
            let scaleX = CGFloat(restored.width) / baseFrame.width
            let scaleY = CGFloat(restored.height) / baseFrame.height
            pixelSize = CGSize(
                width: (selection.width * scaleX).rounded(),
                height: (selection.height * scaleY).rounded()
            )
        } else {
            pixelSize = CGSize(
                width: (selection.width * snapshot.effectiveScale).rounded(),
                height: (selection.height * snapshot.effectiveScale).rounded()
            )
        }
        let text = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
        sizeLabelLayer.set(text: text)
        let size = sizeLabelLayer.calculateSize()

        // 默认放在选区上方外侧；若触顶（靠近屏幕顶部）则移到选区内部左上。
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        if origin.y + size.height > bounds.maxY - 2 {
            origin.y = selection.maxY - size.height - 6
        }
        origin.x = min(max(origin.x, bounds.minX + 2), bounds.maxX - size.width - 2)
        origin.y = min(max(origin.y, bounds.minY + 2), bounds.maxY - size.height - 2)

        sizeLabelLayer.frame = CGRect(origin: origin, size: size)
        sizeLabelLayer.isHidden = false
    }

    private func updateCrosshair() {
        crosshairLayer.path = nil
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

        guard let window = hoveredWindow, let clipped = hoveredWindowPreviewRect else {
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
        if isRecordMode && isWindowOnlyMode {
            text += "  ·  点击要录的窗口  ·  ␣ 切换自由框选  ·  Esc 取消"
        } else if isRecordMode {
            text += "  ·  拖拽框选要录的区域（或点一下某个窗口）  ·  Esc 取消"
        } else if isRegionPickMode {
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
        return .arrow
    }()

    private func updateCursor(at point: CGPoint) {
        if phase == .annotating {
            if let selection, let handle = SelectionGeometry.handle(
                at: point,
                in: selection,
                tolerance: Theme.selectionHandleHitTolerance
            ) {
                SelectionCursor.cursor(for: handle).set()
                return
            }
            let crop = annotationPoint(from: point)
            let target = selectedAnnotation ?? (hoveredAnnotationID.flatMap { id in annotations.first { $0.id == id } })
            if let target, let handle = inlineHitHandle(target, at: crop) {
                SelectionCursor.cursor(forShapeHandle: handle).set()
                return
            }
            if let tool = toolbarModel?.tool {
                if tool == .text {
                    if inlineAnnotation(at: crop) != nil {
                        NSCursor.arrow.set()
                    } else {
                        NSCursor.iBeam.set()
                    }
                } else {
                    NSCursor.arrow.set()
                }
            } else {
                NSCursor.arrow.set()
            }
            return
        }
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
            NSCursor.arrow.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInputArmed else { return }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        if phase == .annotating { return }
        addCursorRect(bounds, cursor: isWindowOnlyMode ? Self.cameraCursor : .arrow)
    }

    // MARK: - Events

    override func mouseMoved(with event: NSEvent) {
        guard isInputArmed else { return }
        requestFocusIfNeeded()
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        if phase == .annotating {
            let crop = annotationPoint(from: point)
            let newHover = inlineAnnotation(at: crop)?.id
            if newHover != hoveredAnnotationID {
                hoveredAnnotationID = newHover
                updateInlineSelectionLayers()
            }
        }
        updateHoveredWindow(at: point)
        updateCrosshair()
        updateLoupe()
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        hoveredWindow = nil
        hoveredAnnotationID = nil
        updateInlineSelectionLayers()
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
            // 裁剪工具自己接管鼠标：在图上任意位置（含正中）按下就能拖出新的裁剪框。
            if cropMouseDown(point, clickCount: event.clickCount) {
                return
            }
            // 选区边缘优先接管：绿框还在，抓着边缘就是继续调区域，框内照旧用来标注。
            if let selection,
                let handle = SelectionGeometry.handle(
                    at: point,
                    in: selection,
                    tolerance: Theme.selectionHandleHitTolerance
                )
            {
                // 整段拖拽算一步撤销（裁剪工具内由完成裁剪统一入栈）。
                if toolbarModel?.tool != .crop {
                    pushUndo()
                }
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
            // 按下的瞬间收起吸附描边（单击命中窗口靠的是 `hoveredWindow` 状态，不影响）。
            updateWindowHighlight()
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
        // 按下的那一刻就收掉吸附描边与窗口标签：视觉焦点交给鼠标开始操作的地方。
        // 只收画面、不动 `hoveredWindow`——单击（没拖过阈值）要按它截图整个窗口。
        updateWindowHighlight()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInputArmed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            // 裁剪工具正拖着一个新裁剪框 → 只更新框，不画标注。
            if cropMouseDragged(point, lockAspect: event.modifierFlags.contains(.shift)) {
                return
            }
            // 正在拖选区边缘 → 继续改区域；否则交给原地标注。
            if case .resizing(let handle, let original) = interaction {
                cursorPoint = point
                let clampBounds = (restoredBaseImage != nil ? restoredImageFrame : nil) ?? canvasBounds
                let updated = SelectionGeometry.resized(
                    original,
                    handle: handle,
                    to: point,
                    clampTo: clampBounds,
                    lockAspect: event.modifierFlags.contains(.shift)
                )
                // 用「上一次的选区」算增量：每次拖拽事件都只平移一次。
                applyRegionResize(from: selection ?? original, to: updated)
                return
            }
            if case .moving(let grabOffset, let original) = interaction {
                cursorPoint = point
                let delta = CGSize(
                    width: point.x - original.minX - grabOffset.width,
                    height: point.y - original.minY - grabOffset.height
                )
                let updated = SelectionGeometry.moved(original, by: delta, clampTo: canvasBounds)
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
            // 裁剪框拖拽收手：框留着（不立刻裁），按 ↵ / 双击 / 「完成裁剪」才动刀。
            if cropMouseUp() {
                return
            }
            // 拖选区边缘或整体移动收手：回到「已定」状态，不把它当成一次标注。
            if case .resizing = interaction {
                interaction = .settled
                if restoredBaseImage != nil && toolbarModel?.tool != .crop {
                    applyDirectResizeCrop()
                }
                return
            }
            if case .moving = interaction {
                interaction = .settled
                return
            }
            inlineMouseUp(point)
            return
        }
        cursorPoint = point

        let wasSelecting: Bool
        if case .selecting = interaction {
            wasSelecting = true
        } else {
            wasSelecting = false
        }

        switch interaction {
        case .pressing:
            // 单击：命中窗口
            if let hoveredWindow {
                // 录屏：不拖也行——点哪个窗口就录哪个窗口。
                if isRecordMode {
                    let rect = DisplayGeometry.localRect(
                        fromCGRect: hoveredWindow.frameInCGPoints, screen: screen
                    ).intersection(canvasBounds)
                    guard !rect.isEmpty else {
                        interaction = .idle
                        return
                    }
                    selection = rect
                    interaction = .settled
                    updateAllLayers()
                    onRecordRegionPicked?(rect)
                    return
                }
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
                    return
                }
                if inlineMode {
                    let rect = DisplayGeometry.localRect(
                        fromCGRect: hoveredWindow.frameInCGPoints,
                        screen: screen
                    ).intersection(canvasBounds)
                    guard !rect.isEmpty else {
                        interaction = .idle
                        return
                    }
                    selection = rect
                    interaction = .settled
                    Self.rememberedSelection[snapshot.displayID] = selection
                    updateAllLayers()
                    enterAnnotating()
                    return
                }
                onWindowSelected?(hoveredWindow)
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

        // 浮窗预览模式：框选区域一松开鼠标就直接完成截图（不用双击 / 回车），交付浮窗与剪贴板。
        if !inlineMode, !isRegionPickMode, !isRecordMode, wasSelecting, isSettled, selection != nil {
            commit()
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

        // 录屏：选区成型就把这块交给外面（控制条会停在「准备录制」，点开始才真开录）。
        if isRecordMode {
            if isSettled, let selection {
                onRecordRegionPicked?(selection)
            } else {
                selection = nil
                interaction = .idle
                updateAllLayers()
            }
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

    // MARK: - Mouse Zoom (Wheel & Pinch) in Annotating Phase

    override func scrollWheel(with event: NSEvent) {
        guard isInputArmed, phase == .annotating, selection != nil else {
            super.scrollWheel(with: event)
            return
        }

        let delta: CGFloat
        if event.hasPreciseScrollingDeltas {
            delta = event.scrollingDeltaY * 0.005
        } else {
            delta = event.deltaY * 0.05
        }
        guard abs(delta) > 0.0001 else { return }

        let factor = max(0.2, min(5.0, 1.0 + delta))
        let point = convert(event.locationInWindow, from: nil)
        zoomSelection(by: factor, at: point)
    }

    override func magnify(with event: NSEvent) {
        guard isInputArmed, phase == .annotating, selection != nil else {
            super.magnify(with: event)
            return
        }

        let factor = 1.0 + event.magnification
        guard factor > 0.01 else { return }
        let point = convert(event.locationInWindow, from: nil)
        zoomSelection(by: factor, at: point)
    }

    private func zoomSelection(by factor: CGFloat, at point: CGPoint) {
        guard let selection, selection.width > 0, selection.height > 0 else { return }
        let currentBase = restoredBaseImage ?? cropImage
        guard let image = currentBase else { return }

        // 若之前尚未接管底图（普通截图原地编辑），缩放时提升到底图图层实现无拉伸高保真缩放
        if restoredBaseImage == nil {
            restoredBaseImage = image
            restoredImageFrame = selection
            preparePreviewBase()
        }

        let baseFrame = restoredImageFrame ?? selection
        let mouseInSelection = CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)
        let aspectRatio = selection.width / selection.height

        let screen = NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID } ?? NSScreen.main
        let screenSize = screen?.visibleFrame.size ?? CGSize(width: 1920, height: 1080)
        let maxSize = CGSize(width: screenSize.width * 3, height: screenSize.height * 3)

        let newSelection = PinGeometry.zoomedFrame(
            currentFrame: selection,
            factor: factor,
            mouseLocationInWindow: mouseInSelection,
            aspectRatio: aspectRatio,
            minSide: 60,
            maxSize: maxSize
        )

        guard newSelection != selection else { return }

        let scale = newSelection.width / selection.width
        let newBaseFrame = CGRect(
            x: newSelection.minX + (baseFrame.minX - selection.minX) * scale,
            y: newSelection.minY + (baseFrame.minY - selection.minY) * scale,
            width: baseFrame.width * scale,
            height: baseFrame.height * scale
        )

        self.selection = newSelection
        self.restoredImageFrame = newBaseFrame

        updateRestoredImageLayer()
        updateDimPath()
        updateSelectionLayers()
        updateAnnotationLayer()
        updateInlineSelectionLayers()
        fitInlineTextField()
        layoutToolbars()
    }

    override func keyDown(with event: NSEvent) {
        guard isInputArmed else { return }
        if phase == .annotating {
            // 撤销 / 重做走设置页配的那两个组合键（默认 ⌘Z / ⇧⌘Z）。
            // 正在改文字时不抢：那时 field editor 才是第一响应者，⌘Z 该撤的是打的字。
            if textField == nil {
                if let hotkey = editorShortcuts.undo, hotkey.matches(event) {
                    inlineUndo()
                    return
                }
                if let hotkey = editorShortcuts.redo, hotkey.matches(event) {
                    inlineRedo()
                    return
                }
                if event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
                    event.charactersIgnoringModifiers?.lowercased() == "s"
                {
                    if let image = currentAnnotatedImage() {
                        onSaveImage?(image)
                        return
                    }
                }
            }
            switch event.keyCode {
            case 53: // Esc
                if toolbarModel?.tool == .crop {
                    cancelCrop()
                    return
                }
                onCancel?()
            case 36, 76: // Return
                if toolbarModel?.tool == .crop {
                    applyCrop()
                    return
                }
                confirmInline()
            case 51, 117: // Delete
                if let selectedID {
                    pushUndo()
                    annotations.removeAll { $0.id == selectedID }
                    self.selectedID = nil
                    updateAnnotationLayer()
                    updateInlineSelectionLayers()
                } else {
                    inlineUndo()
                }
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
        window?.invalidateCursorRects(for: self)
        updateCursor(at: cursorPoint ?? .zero)
    }

    private func exitAnnotating() {
        hideToolbar()
        liveTextHost?.removeFromSuperview()
        liveTextHost = nil
        cropImage = nil
        restoredBaseImage = nil
        restoredImageFrame = nil
        restoredContainerLayer.isHidden = true
        restoredImageLayer.contents = nil
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
        window?.invalidateCursorRects(for: self)
        updateCursor(at: cursorPoint ?? .zero)
    }

    /// 标注态里拖动选区边缘：改选区的同时，把标注 / 橡皮笔迹按**新原点**平移，
    /// 让它们继续钉在画面的同一处（否则会跟着框一起跑）。
    private func applyRegionResize(from previous: CGRect, to updated: CGRect) {
        guard updated != previous else { return }

        // 恢复图片模式下，底图是固定静态像素图，拖动只调整裁剪选区，标注保持相对底图不变
        if restoredBaseImage != nil {
            selection = updated
            updateRestoredImageLayer()
            updateDimPath()
            updateSelectionLayers()
            updateAnnotationLayer()
            updateInlineSelectionLayers()
            layoutToolbars()
            return
        }

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

    // MARK: - Crop actions

    /// 裁剪工具下的按下：双击直接完成裁剪；抓到裁剪框边缘就微调；**在图上任意位置按下
    /// （包括正中间）则拖出一个新的裁剪框**——这正是裁剪与「拖外面那个选框」的区别。
    ///
    /// - Returns: `true` 表示这次按下归裁剪管，调用方不必再走标注那条路。
    private func cropMouseDown(_ point: CGPoint, clickCount: Int) -> Bool {
        guard toolbarModel?.tool == .crop, let bounds = cropBaseFrame else { return false }
        if clickCount >= 2 {
            applyCrop()
            return true
        }
        if cropSessionFrame == nil {
            // 这一轮裁剪的「那张图」先定下来：之后不管框怎么缩，图的边界都留在原位。
            cropSessionFrame = bounds
        }
        if let selection,
            let handle = SelectionGeometry.handle(
                at: point,
                in: selection,
                tolerance: Theme.selectionHandleHitTolerance
            )
        {
            interaction = .resizing(handle: handle, original: selection)
            return true
        }
        // 图外（压暗区 / 工具栏）按下不归裁剪管。
        guard bounds.contains(point) else { return false }
        interaction = .pressing(anchor: point)
        return true
    }

    /// 裁剪框拖拽中：从按下点拉出一个矩形，范围锁在当前底图之内。
    ///
    /// - Returns: `true` 表示这一拖归裁剪管。
    private func cropMouseDragged(_ point: CGPoint, lockAspect: Bool) -> Bool {
        guard toolbarModel?.tool == .crop, let bounds = cropBaseFrame else { return false }
        if case .pressing(let anchor) = interaction {
            // 没超过拖拽阈值就什么都不做：单击不该毁掉已有的裁剪框。
            guard hypot(point.x - anchor.x, point.y - anchor.y) >= Theme.dragActivationDistance else {
                return true
            }
            interaction = .selecting(anchor: anchor)
        }
        guard case .selecting(let anchor) = interaction else { return false }
        cursorPoint = point
        let updated = SelectionGeometry.selectionRect(
            from: anchor,
            to: point,
            clampTo: bounds,
            square: lockAspect
        )
        applyRegionResize(from: selection ?? updated, to: updated)
        return true
    }

    /// 裁剪框拖拽收手：框留着等确认（↵ / 双击 / 「完成裁剪」）；太小的框当作没拖，退回原范围。
    ///
    /// - Returns: `true` 表示这一次收手归裁剪管。
    private func cropMouseUp() -> Bool {
        switch interaction {
        case .pressing:
            // 只是点了一下：保持原裁剪框。
            interaction = .settled
            return true
        case .selecting:
            interaction = .settled
            if let bounds = cropSessionFrame, let selection,
                selection.width < Self.minimumCropSide || selection.height < Self.minimumCropSide
            {
                // 一拖就松的小框：当作单击误触，把范围还回去（顺带把标注的位移还原）。
                applyRegionResize(from: selection, to: bounds)
            }
            return true
        default:
            return false
        }
    }

    /// 裁剪框的可选范围：恢复图片模式是当前底图，普通区域截图是当前那块选区。
    private var cropBaseFrame: CGRect? {
        restoredImageFrame ?? selection
    }

    /// 这一轮裁剪里「正在裁的那张图」占的屏幕矩形（第一次按下时定下，直到确认 / 取消）。
    ///
    /// 裁剪框只标记「要保留哪一块」：图的边界始终留在原位、图本身也不再被压暗层遮住，
    /// 否则框一缩小，框外露出底下的冻结屏幕，就分不清图到哪儿为止了。
    private var cropFrame: CGRect? {
        guard toolbarModel?.tool == .crop else { return nil }
        return cropSessionFrame ?? cropBaseFrame
    }

    /// 还悬着一个「框好了但没落实」的裁剪（框确实比图小，落实下去会真的改变图）。
    private var hasPendingCrop: Bool {
        guard let selection, let frame = cropFrame else { return false }
        return selection != frame
    }

    private func applyCrop() {
        // 框和整张图一样大 = 没裁东西，不占撤销位。
        if hasPendingCrop, let initial = cropInitialState {
            undoStack.append(initial)
            redoStack.removeAll()
        }
        cropInitialState = nil
        cropSessionFrame = nil
        performCropExecution()
        toolbarModel?.tool = nil
        updateRestoredImageLayer()
        updateSelectionLayers()
        updateAnnotationLayer()
        updateDimPath()
        layoutToolbars()
    }

    private func applyDirectResizeCrop() {
        performCropExecution()
        updateRestoredImageLayer()
        updateSelectionLayers()
        updateAnnotationLayer()
        updateDimPath()
        layoutToolbars()
    }

    private func performCropExecution() {
        guard let selection else { return }
        if let restored = restoredBaseImage, let baseFrame = restoredImageFrame {
            let cropRect = selection.intersection(baseFrame)
            guard cropRect.width >= Self.minimumCropSide, cropRect.height >= Self.minimumCropSide else {
                self.selection = baseFrame
                return
            }
            if cropRect != baseFrame {
                let scaleX = CGFloat(restored.width) / baseFrame.width
                let scaleY = CGFloat(restored.height) / baseFrame.height
                let pixelX = (cropRect.minX - baseFrame.minX) * scaleX
                let pixelY = (baseFrame.maxY - cropRect.maxY) * scaleY
                let pixelW = cropRect.width * scaleX
                let pixelH = cropRect.height * scaleY
                let pixelRect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH).integral
                if let result = CropOperation.crop(restored, to: pixelRect) {
                    let delta = CropOperation.offset(for: result.rect)
                    annotations = CropOperation.shifted(annotations, by: delta)
                    eraserStrokes = CropOperation.shifted(eraserStrokes, by: delta)
                    restoredBaseImage = result.image
                    cropImage = result.image
                    self.selection = cropRect
                    self.restoredImageFrame = cropRect
                }
            }
            return
        }

        // 普通截图的原地裁剪
        preparePreviewBase()
    }

    private func cancelCrop() {
        if let initial = cropInitialState {
            apply(initial)
        } else if let restoredBaseImage, let baseFrame = restoredImageFrame {
            selection = baseFrame
        }
        toolbarModel?.tool = nil
        cropInitialState = nil
        cropSessionFrame = nil
        updateRestoredImageLayer()
        updateSelectionLayers()
        updateAnnotationLayer()
        updateDimPath()
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
        applyPendingCropIfNeeded()
        commitPendingInlineText()
        guard let selection else { return nil }
        let base: CGImage
        if let restoredBaseImage {
            base = restoredBaseImage
        } else if let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) {
            base = crop
        } else {
            return nil
        }
        return compose(base: base, annotations: annotations, strokes: eraserStrokes) ?? base
    }

    private func confirmInline() {
        applyPendingCropIfNeeded()
        guard let selection else {
            cancelInline()
            return
        }
        let base: CGImage
        if let restoredBaseImage {
            base = restoredBaseImage
        } else if let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) {
            base = crop
        } else {
            cancelInline()
            return
        }
        commitPendingInlineText()
        let final = compose(base: base, annotations: annotations, strokes: eraserStrokes) ?? base
        let rect = selection
        exitAnnotating()
        onCommitAnnotated?(final, rect)
    }

    /// 交出去之前先把「框好了但还没落实」的裁剪落实掉。
    ///
    /// 裁剪是「先框、后确认」：用户框完直接点主工具栏的 ✓（或保存 / 钉图）时，
    /// 若不管这个框，交出去的还是没裁过的原图——看到的就是「裁完怎么还是原来那张」。
    private func applyPendingCropIfNeeded() {
        guard hasPendingCrop else { return }
        applyCrop()
    }

    /// 记住选区对应的原图。标注层就直接按它的原始分辨率渲染（见 `updateAnnotationLayer`）。
    private func preparePreviewBase() {
        if let restoredBaseImage {
            cropImage = restoredBaseImage
            updateRestoredImageLayer()
            return
        }
        guard let selection, let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) else {
            cropImage = nil
            return
        }
        cropImage = crop
    }

    private func updateAnnotationLayer() {
        toolbarModel?.canUndo = !undoStack.isEmpty
        toolbarModel?.canRedo = !redoStack.isEmpty

        // 草稿要「有实际尺寸」才画；单击产生的零尺寸草稿不显示，避免闪一下。
        var list = annotations
        if let editingID = inlineEditingTextID {
            list.removeAll { $0.id == editingID }
        }
        if let annotationDraft, isMeaningfulDraft(annotationDraft) {
            list.append(annotationDraft)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard let base = baseImageInView, let frame = baseFrameInView, !list.isEmpty else {
            annotationLayer.contents = nil
            annotationLayer.isHidden = true
            CATransaction.commit()
            return
        }
        // 标注层按**原图分辨率**渲染一张透明底的「标注图层」，叠在冻结图之上：
        // 1:1 落在屏幕上，线 / 箭头不会有缩放锯齿；又因为不用每帧重画底图，
        // 比之前「缩到 1600 再画底图」还快（实测 2560 宽的选区 0.5ms vs 1.7ms）。
        let image = compose(
            base: base,
            annotations: list,
            strokes: eraserStrokes,
            drawsBase: false
        )
        // 贴**底图**的 frame（不是选区）：裁剪 / 缩放时选区会变，底图不变。
        annotationLayer.frame = frame
        annotationLayer.contents = image
        annotationLayer.isHidden = false
        CATransaction.commit()
    }

    /// 依次绘制标注（含按先后顺序擦除恢复底图的橡皮）。
    ///
    /// `drawsBase = false` 时输出透明底的标注图层（供原地预览叠在冻结图上）。
    private func compose(
        base: CGImage,
        annotations: [Annotation],
        strokes: [EraserStroke],
        drawsBase: Bool = true
    ) -> CGImage? {
        AnnotationRenderer.render(
            base: base,
            annotations: annotations,
            eraserStrokes: strokes,
            drawsBase: drawsBase
        )
    }

    /// 草稿是否已经「成形」（用于避免单击时的零尺寸闪烁）。
    private func isMeaningfulDraft(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle(let rect), .ellipse(let rect), .spotlight(let rect), .pixelate(let rect, _),
            .blur(let rect, _):
            return rect.width >= 1.5 || rect.height >= 1.5
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 2
        case .line(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= 2
        case .pen(let points), .highlight(let points):
            return points.count >= 2
        case .counter, .callout, .eraser:
            return true
        case .text:
            return false
        }
    }

    private func pushUndo() {
        undoStack.append(
            Snapshot(
                annotations: annotations,
                strokes: eraserStrokes,
                selection: selection,
                restoredBaseImage: restoredBaseImage,
                restoredImageFrame: restoredImageFrame
            )
        )
        redoStack.removeAll()
    }

    private func inlineUndo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(
            Snapshot(
                annotations: annotations,
                strokes: eraserStrokes,
                selection: selection,
                restoredBaseImage: restoredBaseImage,
                restoredImageFrame: restoredImageFrame
            )
        )
        apply(previous)
    }

    private func inlineRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(
            Snapshot(
                annotations: annotations,
                strokes: eraserStrokes,
                selection: selection,
                restoredBaseImage: restoredBaseImage,
                restoredImageFrame: restoredImageFrame
            )
        )
        apply(next)
    }

    private func apply(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        eraserStrokes = snapshot.strokes

        let imageChanged = snapshot.restoredBaseImage !== restoredBaseImage
        restoredBaseImage = snapshot.restoredBaseImage
        restoredImageFrame = snapshot.restoredImageFrame

        let selectionChanged = snapshot.selection != selection || imageChanged
        selection = snapshot.selection
        if selectionChanged {
            preparePreviewBase()
            updateDimPath()
            updateSelectionLayers()
            updateRestoredImageLayer()
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
            case .rectangle, .ellipse, .spotlight, .highlight, .pixelate, .pen, .text:
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
        if annotation.supportsRotation {
            handles.append((.rotate, ShapeGeometry.rotateHandle(for: annotation, distance: 28)))
        }
        return handles
    }

    private func updateInlineSelectionLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let target = selectedAnnotation ?? (hoveredAnnotationID.flatMap { id in annotations.first { $0.id == id } })

        guard phase == .annotating, let target, inlineEditingTextID == nil else {
            inlineSelectionBorderLayer.isHidden = true
            inlineHandlesLayer.isHidden = true
            inlineSelectionBorderLayer.path = nil
            inlineHandlesLayer.path = nil
            return
        }

        let corners = target.rotatedCorners().map { viewPoint($0) }
        let border = CGMutablePath()
        border.addLines(between: corners)
        border.closeSubpath()
        inlineSelectionBorderLayer.path = border
        inlineSelectionBorderLayer.isHidden = false

        let path = CGMutablePath()
        let radius = Self.inlineHandleRadius
        for (_, point) in inlineHandles(for: target) {
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
        model.tool = nil
        model.color = seed.color
        model.lineWidth = seed.lineWidth
        model.highlightColor = seed.highlightColor
        model.highlightLineWidth = seed.highlightLineWidth
        model.fontSize = seed.fontSize
        model.eraserSize = seed.eraserSize
        model.mosaicBlock = seed.mosaicBlock
        model.blurRadius = seed.blurRadius
        model.arrowStyle = seed.arrowStyle
        model.shapeFillMode = seed.shapeFillMode
        model.rectCornerStyle = seed.rectCornerStyle
        model.textHasStroke = seed.textHasStroke
        model.textHasCallout = seed.textHasCallout
        model.editorShortcuts = editorShortcuts
        model.isRestoredImage = (restoredBaseImage != nil)
        model.allowsCrop = allowsCrop
        model.onConfirm = { [weak self] in self?.confirmInline() }
        model.onCancel = { [weak self] in self?.onCancel?() }
        model.onUndo = { [weak self] in self?.inlineUndo() }
        model.onRedo = { [weak self] in self?.inlineRedo() }
        model.onApplyCrop = { [weak self] in self?.applyCrop() }
        model.onTextStyleChange = { [weak self] effect in
            self?.applyTextStyleToSelection(effect)
        }
        model.onCancelCrop = { [weak self] in self?.cancelCrop() }
        model.onSave = { [weak self] in
            guard let self, let image = self.currentAnnotatedImage() else { return }
            self.onSaveImage?(image)
        }
        model.onPin = { [weak self] in
            guard let self, let image = self.currentAnnotatedImage() else { return }
            self.onPinImage?(image, self.selection ?? .zero)
        }
        model.onScrollCapture = { [weak self] mode in self?.beginScrollCapture(mode: mode) }
        // 工具栏的「录屏」：和「框好一块区域去录屏」走的是同一条交接（`onRecordRegionPicked`），
        // 区别只是这回选区是用户在就地工具栏前调好的。
        model.onRecord = { [weak self] in
            guard let self, let selection = self.selection else { return }
            self.onRecordRegionPicked?(selection)
        }
        toolbarModel = model

        // 主工具栏：固定尺寸，永不重算 → 展开选项时也不闪烁。
        let main = NSHostingView(rootView: InlineMainToolbar(model: model))
        main.translatesAutoresizingMaskIntoConstraints = true
        main.layer?.masksToBounds = false
        addSubview(main)
        mainToolbarHost = main

        // 二级菜单：持久宿主，只靠 SwiftUI 内部响应驱动，避免拖拽滑块/调色时宿主反复重建闪烁
        let options = NSHostingView(rootView: InlineOptionsToolbar(model: model))
        options.translatesAutoresizingMaskIntoConstraints = true
        options.layer?.masksToBounds = false
        options.isHidden = !model.isSubToolbarVisible
        addSubview(options)
        optionsToolbarHost = options

        layoutToolbars()

        // 监听工具/参数变化以更新选项条与存档。
        observeOptions(model)
        observeDefaults(model)
    }

    /// 工具 / 颜色 / 参数变化时回报，由外部落盘（下次截图沿用）。
    private func observeDefaults(_ model: InlineToolbarModel) {
        withObservationTracking {
            _ = model.tool
            _ = model.color
            _ = model.lineWidth
            _ = model.highlightColor
            _ = model.highlightLineWidth
            _ = model.fontSize
            _ = model.eraserSize
            _ = model.mosaicBlock
            _ = model.blurRadius
            _ = model.arrowStyle
            _ = model.shapeFillMode
            _ = model.rectCornerStyle
            _ = model.textHasStroke
            _ = model.textHasCallout
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.toolbarModel === model else { return }
                self.onAnnotationDefaultsChange?(
                    AnnotationDefaults(
                        tool: model.tool ?? self.annotationDefaults.tool,
                        color: model.color,
                        lineWidth: model.lineWidth,
                        highlightColor: model.highlightColor,
                        highlightLineWidth: model.highlightLineWidth,
                        fontSize: model.fontSize,
                        mosaicBlock: model.mosaicBlock,
                        blurRadius: model.blurRadius,
                        eraserSize: model.eraserSize,
                        arrowStyle: model.arrowStyle,
                        shapeFillMode: model.shapeFillMode,
                        rectCornerStyle: model.rectCornerStyle,
                        textHasStroke: model.textHasStroke,
                        textHasCallout: model.textHasCallout
                    )
                )
                self.observeDefaults(model)
            }
        }
    }

    /// 就地编辑工具栏里选了「手动 / 自动滚动」：把当前选区交给外面开跑滚动长图。
    ///
    /// 这里只做「收起自己的选项条 + 上报」：真正的会话要建控制条与实时预览、还要把遮罩
    /// 换成取景框（鼠标穿透），那是 AppDelegate 那一层的事。
    private func beginScrollCapture(mode: ScrollingCaptureSession.Mode) {
        guard let selection else { return }
        toolbarModel?.showScroll = false
        onScrollCapture?(mode, selection)
    }

    #if DEBUG
    /// 自检用：等价于点一下工具栏的「滚动截图」（只展开选项，不真的开跑）。
    @discardableResult
    func debugOpenScrollOptions() -> Bool {
        guard toolbarModel != nil, selection != nil else { return false }
        toolbarModel?.showScroll = true
        return true
    }

    /// 自检用：等价于点一下工具栏的「录屏」。
    @discardableResult
    func debugTriggerRecord() -> Bool {
        guard toolbarModel != nil, selection != nil else { return false }
        onRecordRegionPicked?(selection!)
        return true
    }

    /// 自检用：等价于点一下工具栏的「滚动截图」→ 选某个模式。
    @discardableResult
    func debugTriggerScrollCapture(_ mode: ScrollingCaptureSession.Mode) -> Bool {
        guard toolbarModel != nil, selection != nil else { return false }
        toolbarModel?.showScroll = true
        beginScrollCapture(mode: mode)
        return true
    }
    #endif

    private func hideToolbar() {
        mainToolbarHost?.removeFromSuperview()
        mainToolbarHost = nil
        optionsToolbarHost?.removeFromSuperview()
        optionsToolbarHost = nil
        toolbarModel = nil
    }

    /// 工具/参数/子工具栏开关变化时重新排版选项条。
    private func observeOptions(_ model: InlineToolbarModel) {
        withObservationTracking {
            _ = model.isSubToolbarVisible
            _ = model.tool
            _ = model.showScroll
            _ = model.isLiveTextActive
            if self.textField != nil {
                _ = model.fontSize
                _ = model.color
                _ = model.textHasStroke
                _ = model.textHasCallout
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if let field = self.textField {
                    self.applyInlineTextStyle(field, model: model)
                    self.fitInlineTextField()
                }

                if model.tool == .crop && self.cropInitialState == nil {
                    self.cropInitialState = Snapshot(
                        annotations: self.annotations,
                        strokes: self.eraserStrokes,
                        selection: self.selection,
                        restoredBaseImage: self.restoredBaseImage,
                        restoredImageFrame: self.restoredImageFrame
                    )
                } else if model.tool != .crop {
                    self.cropInitialState = nil
                    self.cropSessionFrame = nil
                }
                // 进出裁剪都要重画：裁剪时压暗层挖的是整张图、还要给底图画外框（见 `updateCropFrameBorder`）。
                self.updateDimPath()
                self.updateSelectionLayers()
                self.optionsToolbarHost?.isHidden = !model.isSubToolbarVisible
                self.updateLiveTextOverlay()
                self.layoutToolbars()
                if self.toolbarModel === model {
                    self.observeOptions(model)
                }
            }
        }
    }

    /// 用户点了文字二级菜单里的「描边 / 标注」：把这一项**当场**刷到选中的那条文字上。
    ///
    /// 只由那个开关的回调触发（`onTextStyleChange`），**不能**挂在工具栏的通用观察上——
    /// 否则选中一条文字之后，换个工具 / 调个颜色都会拿工具栏当前值去覆盖它，把已有样式改坏。
    /// 也只动被点的那一项：点「描边」不该顺手把这条文字上的「标注」也改掉。
    /// 正在输入文字时走的是文本框那条路（`applyInlineTextStyle`），这里只管「没在输入、但选中了一条文字」。
    private func applyTextStyleToSelection(_ effect: InlineToolbarModel.TextEffect) {
        guard textField == nil, let model = toolbarModel, let selectedID,
            let index = annotations.firstIndex(where: { $0.id == selectedID }),
            case .text = annotations[index].kind
        else { return }
        let updated: Annotation
        switch effect {
        case .stroke: updated = annotations[index].withTextStroke(model.textHasStroke)
        case .callout: updated = annotations[index].withTextCallout(model.textHasCallout)
        }
        guard updated != annotations[index] else { return }
        // 开关是离散的（不像滑块会连着刷），一次切换算一步撤销。
        pushUndo()
        annotations[index] = updated
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }

    /// 实况文本：选中「选择」工具时铺一层可拖选复制文字的覆盖层。
    private func updateLiveTextOverlay() {
        let wantsLiveText = (toolbarModel?.isLiveTextActive ?? false) && cropImage != nil && selection != nil
        if wantsLiveText {
            if liveTextHost == nil, let image = baseImageInView {
                let host = NSHostingView(rootView: LiveTextOverlay(image: image))
                host.translatesAutoresizingMaskIntoConstraints = true
                addSubview(host)
                liveTextHost = host
            }
            if let host = liveTextHost, let frame = baseFrameInView {
                // 覆盖层是**底图**的一片，跟着底图的 frame 走（与标注层同一套基准）。
                host.frame = frame
            }
        } else {
            liveTextHost?.removeFromSuperview()
            liveTextHost = nil
        }
    }

    private func rebuildOptionsToolbar() {
        optionsToolbarHost?.isHidden = !(toolbarModel?.isSubToolbarVisible ?? false)
        layoutToolbars()
    }

    /// 摆工具栏：**默认贴在选区下面**；下面放不下，就看看左右两侧有没有位置，
    /// 有就竖排停到那一侧；两边都放不下才退回选区上方（兜底，别把工具栏弄丢）。
    private func layoutToolbars() {
        guard let selection, let main = mainToolbarHost else { return }
        let inset: CGFloat = 8
        let gap: CGFloat = 10

        let horizontalSize = measureMainToolbar(vertical: false)
        if selection.minY - gap - horizontalSize.height >= bounds.minY + inset {
            placeHorizontal(main, size: horizontalSize, below: selection, inset: inset, gap: gap)
            layoutOptions(beside: main.frame, side: nil, inset: inset, gap: gap)
            return
        }

        let verticalSize = measureMainToolbar(vertical: true)
        if let side = verticalDockSide(for: selection, mainSize: verticalSize, inset: inset, gap: gap) {
            placeVertical(main, size: verticalSize, on: side, selection: selection, inset: inset, gap: gap)
            layoutOptions(beside: main.frame, side: side, inset: inset, gap: gap)
            return
        }

        // 兜底：左右也没有位置 → 横排贴到选区上方。
        let size = measureMainToolbar(vertical: false)
        placeHorizontal(main, size: size, below: selection, inset: inset, gap: gap, above: true)
        layoutOptions(beside: main.frame, side: nil, inset: inset, gap: gap)
    }

    /// 量一次主工具栏在某个方向上的尺寸（`isVerticalLayout` 变了要让它先重新排一遍）。
    private func measureMainToolbar(vertical: Bool) -> CGSize {
        guard let main = mainToolbarHost, let model = toolbarModel else { return .zero }
        if model.isVerticalLayout != vertical {
            model.isVerticalLayout = vertical
            main.layoutSubtreeIfNeeded()
        }
        return main.fittingSize
    }

    /// 横排：水平居中于选区，放在选区下面（`above = true` 时放上面）。
    private func placeHorizontal(
        _ main: NSView,
        size: CGSize,
        below selection: CGRect,
        inset: CGFloat,
        gap: CGFloat,
        above: Bool = false
    ) {
        var origin = CGPoint(
            x: selection.midX - size.width / 2,
            y: above ? selection.maxY + gap : selection.minY - size.height - gap
        )
        origin.x = min(
            max(origin.x, bounds.minX + inset),
            max(bounds.minX + inset, bounds.maxX - size.width - inset)
        )
        origin.y = min(max(origin.y, bounds.minY + inset), bounds.maxY - size.height - inset)
        main.frame = CGRect(origin: origin, size: size)
    }

    /// 竖排能停在哪一侧？优先右侧，其次左侧；都放不下返回 nil。
    private func verticalDockSide(
        for selection: CGRect,
        mainSize: CGSize,
        inset: CGFloat,
        gap: CGFloat
    ) -> VerticalDockSide? {
        guard mainSize.width > 0, mainSize.height > 0 else { return nil }
        // 竖排要够高（工具栏很长），也要在选区旁边放得下。
        guard mainSize.height <= bounds.height - inset * 2 else { return nil }
        let optionsSize = visibleOptionsSize()
        let columnWidth = mainSize.width + (optionsSize.width > 0 ? gap + optionsSize.width : 0)
        let roomLeft = selection.minX - bounds.minX
        let roomRight = bounds.maxX - selection.maxX
        if roomRight >= columnWidth + gap + inset { return .right }
        if roomLeft >= columnWidth + gap + inset { return .left }
        return nil
    }

    /// 竖排：贴边停靠，整体在竖直方向居中于选区（并夹进画布）。
    private func placeVertical(
        _ main: NSView,
        size: CGSize,
        on side: VerticalDockSide,
        selection: CGRect,
        inset: CGFloat,
        gap: CGFloat
    ) {
        // **贴着选区**摆（不是贴屏幕边）：选区右边放不下才轮到左边，两边都放不下则走兜底。
        let x = side == .right ? selection.maxX + gap : selection.minX - gap - size.width
        var y = selection.midY - size.height / 2
        y = min(max(y, bounds.minY + inset), max(bounds.minY + inset, bounds.maxY - size.height - inset))
        main.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private enum VerticalDockSide {
        case left
        case right
    }

    /// 二级菜单当前的尺寸（不显示时为零）。
    private func visibleOptionsSize() -> CGSize {
        guard let options = optionsToolbarHost, let model = toolbarModel, model.isSubToolbarVisible
        else { return .zero }
        options.layoutSubtreeIfNeeded()
        return options.fittingSize
    }

    /// 摆二级菜单：贴着主工具栏。
    ///
    /// - 横排（`side == nil`）：居中挂在主栏正下方，放不下就翻到主栏上面。
    /// - 竖排：也跟着竖排，挂在主栏**外侧**（离选区远的那一边），顶部与主栏对齐。
    private func layoutOptions(
        beside mainFrame: CGRect,
        side: VerticalDockSide?,
        inset: CGFloat,
        gap: CGFloat
    ) {
        guard let options = optionsToolbarHost, let model = toolbarModel, model.isSubToolbarVisible else {
            optionsToolbarHost?.isHidden = true
            return
        }
        options.isHidden = false
        let size = visibleOptionsSize()
        guard size.width > 0, size.height > 0 else { return }

        if let side {
            // 主栏贴着选区，二级菜单挂在主栏**外侧**（离选区远的那一边），别挤在选区和主栏中间；
            // 竖直方向与主栏**上下居中**（主栏本身相对选区居中，这样两条栏看着是一体的）。
            var x = side == .right ? mainFrame.maxX + gap : mainFrame.minX - gap - size.width
            x = min(max(x, bounds.minX + inset), max(bounds.minX + inset, bounds.maxX - size.width - inset))
            let y = min(
                max(mainFrame.midY - size.height / 2, bounds.minY + inset),
                max(bounds.minY + inset, bounds.maxY - size.height - inset)
            )
            options.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            return
        }

        let x = min(
            max(mainFrame.midX - size.width / 2, bounds.minX + inset),
            max(bounds.minX + inset, bounds.maxX - size.width - inset)
        )
        var y = mainFrame.minY - inset - size.height
        if y < bounds.minY + inset {
            y = mainFrame.maxY + inset
        }
        y = min(max(y, bounds.minY + inset), max(bounds.minY + inset, bounds.maxY - size.height - inset))
        options.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Eraser (see compose)

    // MARK: Inline geometry    // MARK: Inline geometry

    /// 屏幕上**底图**占的矩形：恢复图片模式是底图自己的 frame，普通区域截图就是当前选区。
    ///
    /// 标注的坐标换算一律以它为准。裁剪框（或缩放）改动的是**选区**——「要保留哪一块」的框，
    /// 底图并没有跟着变形；拿选区当基准的话，一拖裁剪框标注就会被压扁、点也点不准。
    private var baseFrameInView: CGRect? {
        restoredImageFrame ?? selection
    }

    /// 底图的像素图（标注层 / 实况文本的渲染源），与 `baseFrameInView` 成对使用。
    private var baseImageInView: CGImage? {
        restoredBaseImage ?? cropImage
    }

    /// 视图坐标（原点左下）→ 底图像素坐标（原点左上）。
    private func annotationPoint(from point: CGPoint) -> CGPoint {
        guard let frame = baseFrameInView, frame.width > 0, frame.height > 0 else { return .zero }
        let scaleX: CGFloat
        let scaleY: CGFloat
        if let base = baseImageInView {
            scaleX = CGFloat(base.width) / frame.width
            scaleY = CGFloat(base.height) / frame.height
        } else {
            scaleX = snapshot.effectiveScale
            scaleY = snapshot.effectiveScale
        }
        return CGPoint(
            x: (point.x - frame.minX) * scaleX,
            y: (frame.maxY - point.y) * scaleY
        )
    }

    /// 底图像素坐标 → 视图坐标（原点左下）。
    private func viewPoint(fromAnnotation point: CGPoint) -> CGPoint {
        guard let frame = baseFrameInView, frame.width > 0, frame.height > 0 else { return .zero }
        let scaleX: CGFloat
        let scaleY: CGFloat
        if let base = baseImageInView {
            scaleX = CGFloat(base.width) / frame.width
            scaleY = CGFloat(base.height) / frame.height
        } else {
            scaleX = snapshot.effectiveScale
            scaleY = snapshot.effectiveScale
        }
        return CGPoint(x: frame.minX + point.x / scaleX, y: frame.maxY - point.y / scaleY)
    }

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        viewPoint(fromAnnotation: point)
    }

    private func makeInlineDraft(start: CGPoint, current: CGPoint) -> Annotation? {
        guard let model = toolbarModel, let tool = model.tool else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
        switch tool {
        case .rectangle:
            return Annotation(
                kind: .rectangle(rect),
                color: model.color,
                lineWidth: model.lineWidth,
                shapeFillMode: model.shapeFillMode,
                rectCornerStyle: model.rectCornerStyle
            )
        case .ellipse:
            return Annotation(
                kind: .ellipse(rect),
                color: model.color,
                lineWidth: model.lineWidth,
                shapeFillMode: model.shapeFillMode
            )
        case .highlight:
            // 荧光笔不是「拉一个框涂色」，是拿笔刷沿手指涂一条（参考 capcap 的高亮笔）。
            return Annotation(
                kind: .highlight(points: [start, current]),
                color: model.highlightColor,
                lineWidth: model.highlightLineWidth
            )
        case .spotlight:
            return Annotation(kind: .spotlight(rect), color: model.color, lineWidth: model.lineWidth)
        case .pixelate:
            return Annotation(kind: .pixelate(rect, block: model.mosaicBlock), color: model.color, lineWidth: model.lineWidth)
        case .blur:
            return Annotation(kind: .blur(rect, radius: model.blurRadius), color: model.color, lineWidth: model.lineWidth)
        case .arrow:
            return Annotation(
                kind: .arrow(from: start, to: current, control: nil),
                color: model.color,
                lineWidth: model.lineWidth,
                arrowStyle: model.arrowStyle
            )
        case .line:
            return Annotation(kind: .line(from: start, to: current), color: model.color, lineWidth: model.lineWidth)
        case .pen:
            return Annotation(kind: .pen(points: [start, current]), color: model.color, lineWidth: model.lineWidth)
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
        case .rectangle(let rect), .ellipse(let rect), .spotlight(let rect), .pixelate(let rect, _),
            .blur(let rect, _):
            return rect.width >= 3 && rect.height >= 3
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 3
        case .line(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= 3
        case .counter, .callout, .pen, .highlight, .text, .eraser:
            return true
        }
    }

    /// 统一的原地鼠标处理：先命中已有对象（任意工具下都可编辑），空白处才新建。
    private func inlineMouseDown(_ point: CGPoint, clickCount: Int) {
        // 点别处一律先把正在编辑的文字落地。
        commitPendingInlineText()
        let crop = annotationPoint(from: point)
        let tool = toolbarModel?.tool

        // 橡皮：画笔式擦除（按绘制顺序擦除并恢复底图）。
        if tool == .eraser {
            guard let selection, selection.contains(point) else { return }
            commitPendingInlineText()
            pushUndo()
            erasing = true
            lastErasePoint = crop
            let radius = max(3, (toolbarModel?.eraserSize ?? 28) / 2 * snapshot.effectiveScale)
            let eraserAnnotation = Annotation(
                kind: .eraser(points: [crop], radius: radius),
                color: .white,
                lineWidth: radius * 2
            )
            annotations.append(eraserAnnotation)
            updateAnnotationLayer()
            return
        }

        // 1) 选中对象 + 命中控制点 → 缩放 / 旋转 / 端点（非自由涂抹工具下）
        let activeTarget = selectedAnnotation ?? (hoveredAnnotationID.flatMap { id in annotations.first { $0.id == id } })
        if tool != .pen, tool != .highlight,
            let target = activeTarget,
            let handle = inlineHitHandle(target, at: crop)
        {
            selectedID = target.id
            pushUndo()
            switch handle {
            case .rotate:
                let angle = atan2(crop.y - target.center.y, crop.x - target.center.x)
                inlineEditDrag = .rotating(id: target.id, startAngle: angle, original: target)
            case .arrowStart, .arrowEnd, .arrowControl, .counterLeader:
                inlineEditDrag = .endpoint(id: target.id, handle: handle, original: target)
            default:
                inlineEditDrag = .resizing(id: target.id, handle: handle, original: target)
            }
            updateInlineSelectionLayers()
            return
        }

        // 2) 命中已有标注 → 选中并移动（非自由涂抹工具下）
        if tool != .pen, tool != .highlight, let hit = inlineAnnotation(at: crop) {
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

        // 3) 空白：清空选中；若当前未选工具则支持双击完成 / 拖动选框；若选了绘制工具则开始新标注
        selectedID = nil
        inlineEditDrag = .none
        updateInlineSelectionLayers()
        guard let tool else {
            if clickCount >= 2 {
                confirmInline()
                return
            }
            if restoredBaseImage == nil, let selection, selection.contains(point) {
                pushUndo()
                interaction = .moving(
                    grabOffset: CGSize(
                        width: point.x - selection.minX,
                        height: point.y - selection.minY
                    ),
                    original: selection
                )
            }
            return
        }

        // 绘制工具必须在选区内点击才能开始绘制！选区外（包括工具栏周围）点击绝不开始绘制。
        guard let selection, selection.contains(point) else { return }
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
            if let last = annotations.last, case .eraser(var points, let radius) = last.kind {
                points.append(crop)
                annotations[annotations.count - 1].kind = .eraser(points: points, radius: radius)
            }
            lastErasePoint = crop
            updateAnnotationLayer()
            return
        }

        if inlineDragging, let model = toolbarModel {
            // 画笔与荧光笔都是**连续笔迹**：一路把点攒起来，而不是只留起点终点。
            if model.tool == .pen, case .pen(var points) = annotationDraft?.kind {
                points.append(crop)
                annotationDraft?.kind = .pen(points: points)
            } else if model.tool == .highlight, case .highlight(var points) = annotationDraft?.kind {
                points.append(crop)
                annotationDraft?.kind = .highlight(points: points)
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

        if let editing {
            model.color = editing.color
            model.textHasStroke = editing.textHasStroke
            model.textHasCallout = editing.textHasCallout
            if case .text(_, _, let size) = editing.kind {
                model.fontSize = size / snapshot.effectiveScale
            }
        }

        let existing: String
        if case .text(_, let string, _)? = editing?.kind {
            existing = string
        } else {
            existing = ""
        }

        let field = InlineTextField(frame: .zero)
        field.stringValue = existing
        field.target = self
        field.action = #selector(handleInlineTextCommit)
        field.onCancelScreenshot = { [weak self] in
            self?.onCancel?()
        }
        field.onCommit = { [weak self] in
            self?.commitPendingInlineText()
        }
        field.onTextWidthChange = { [weak self] in
            self?.fitInlineTextField()
        }
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
        field.attachEditorObservers()
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }

    /// 字号 / 颜色 / 特效都跟最终渲染一致（系统字体 + 标注色 + 气泡底板/描边），这才是「所见即所得」。
    private func applyInlineTextStyle(_ field: InlineTextField, model: InlineToolbarModel) {
        field.applyStyle(
            fontSize: model.fontSize,
            color: model.color,
            hasStroke: model.textHasStroke,
            hasCallout: model.textHasCallout
        )
    }

    /// 框贴着文字宽度与行高，保证打字与成图严格像素对齐。
    /// 支持中文拼音输入时的实时动态宽度自适应与气泡内边距补偿。
    private func fitInlineTextField() {
        guard let field = textField else { return }
        let viewOrigin = viewPoint(fromAnnotation: inlineTextOrigin)
        field.fitToOrigin(viewOrigin, isFlipped: false)
    }

    @objc private func inlineTextDidChange() {
        fitInlineTextField()
    }

    @objc private func handleInlineTextCommit() {
        commitPendingInlineText()
    }

    private func commitPendingInlineText() {
        guard let field = textField, let model = toolbarModel else { return }
        window?.makeFirstResponder(self)
        field.detachEditorObservers()
        NotificationCenter.default.removeObserver(
            self, name: NSControl.textDidChangeNotification, object: field
        )
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = inlineTextOrigin
        let editingID = inlineEditingTextID
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
            annotations[index] = annotations[index]
                .withText(string)
                .withTextStroke(model.textHasStroke)
                .withTextCallout(model.textHasCallout)
            selectedID = editingID
        } else {
            let annotation = Annotation(
                kind: .text(
                    origin: origin,
                    string: string,
                    fontSize: max(12, model.fontSize * snapshot.effectiveScale)
                ),
                color: model.color,
                lineWidth: model.lineWidth,
                arrowStyle: model.arrowStyle,
                shapeFillMode: model.shapeFillMode,
                textHasStroke: model.textHasStroke,
                textHasCallout: model.textHasCallout
            )
            annotations.append(annotation)
            selectedID = annotation.id
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
        if selection == nil, let windowRect = hoveredWindowLocalRect {
            selection = windowRect
            updateAllLayers()
            interaction = .settled
            Self.rememberedSelection[snapshot.displayID] = windowRect
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

/// 选区尺寸胶囊标签图层：使用 CoreText 绘制单行尺寸文本，上下左右留白精确对称，避免垂直偏心错位。
nonisolated final class PillLabelLayer: CALayer {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private var text: String = ""
    private var textWidth: CGFloat = 0

    override init() {
        super.init()
        backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        cornerRadius = 4
        masksToBounds = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? PillLabelLayer {
            self.text = other.text
            self.textWidth = other.textWidth
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func action(forKey event: String) -> CAAction? {
        nil
    }

    func set(text: String) {
        guard self.text != text else { return }
        self.text = text
        let attr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.cgColor,
        ]
        let attrString = NSAttributedString(string: text, attributes: attr)
        let line = CTLineCreateWithAttributedString(attrString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        setNeedsDisplay()
    }

    func calculateSize() -> CGSize {
        let paddingH: CGFloat = 7
        let paddingV: CGFloat = 5
        let w = ceil(textWidth + paddingH * 2)
        let h = ceil(font.capHeight + paddingV * 2)
        return CGSize(width: w, height: h)
    }

    override func draw(in ctx: CGContext) {
        guard !text.isEmpty else { return }
        let attr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.cgColor,
        ]
        let attrString = NSAttributedString(string: text, attributes: attr)
        let line = CTLineCreateWithAttributedString(attrString)
        let y = (bounds.height - font.capHeight) / 2
        let x = (bounds.width - textWidth) / 2
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
}

