import AppKit
import SwiftUI
import os

/// 遮罩画布：选区状态机 + 全部视觉层。
///
/// 分层设计（性能关键）：整屏冻结图放在**静态**的 `imageLayer` 里永不重绘，
/// 鼠标移动只更新十字线、放大镜、尺寸标签这几个小图层。若把图像画进 `draw(_:)`，
/// 6K 分辨率下每帧都要重新合成整屏，拖动会明显掉帧。
final class OverlayCanvasView: NSView {
    let logger = Logger(subsystem: "com.ixxxxoooo.jietu", category: "overlay")

    // MARK: - Inputs

    let snapshot: DisplaySnapshot
    let session: CaptureSession
    let displayIndex: Int
    let displayCount: Int

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
    static let regionPickPauseDelay: TimeInterval = 0.35
    var pauseWorkItem: DispatchWorkItem?

    /// 原地编辑恢复图片时，四周至少让出的空间（point）。
    ///
    /// 下方这一条正是工具栏的位置：主栏（~46）+ 间距（10）+ 二级参数栏（~46）+ 收边（8）
    /// 叠起来刚好 ~120，所以 `minY` 不低于它时两条工具栏都能摆在图片下面，不会压住图。
    static let inlineEditorBottomInset: CGFloat = 120
    /// 上 / 左右只留一点呼吸感，够放得下就按原尺寸来。
    static let inlineEditorEdgeInset: CGFloat = 40

    /// 裁剪框的最小边长：比它小的一拖当作「没拖」（单击误触），不参与裁剪。
    static let minimumCropSide: CGFloat = 10

    // MARK: - State

    enum Interaction {
        case idle
        /// 已按下但还没超过拖拽阈值。
        case pressing(anchor: CGPoint)
        case selecting(anchor: CGPoint)
        /// 已有选区且空闲。
        case settled
        case resizing(handle: SelectionHandle, original: CGRect)
        case moving(grabOffset: CGSize, original: CGRect)
    }

    var interaction: Interaction = .idle
    var selection: CGRect?
    var hoveredWindow: WindowInfo?
    var cursorPoint: CGPoint?

    // MARK: - Loupe（跟随光标的像素放大镜）

    /// 放大镜卡片（镜面 + 坐标 / 区域 / 色值）：鼠标走到哪跟到哪，用来对着像素抠选区。
    ///
    /// 尺寸与外观全在 `PixelLoupeCard` 里 —— 和取色器那张卡是同一个组件，不在这里重描。
    let loupeCardModel = LoupeCardModel()
    var loupeCardHost: PixelLoupeCardHost<LoupeReadoutCard>?
    /// 镜面现在取的采样窗口（图像像素、原点左上）：窗口没换就不重新裁图。
    var loupeSourceOrigin: CGPoint?
    var lastSampledPixel: CGPoint?

    #if DEBUG
    /// 自检用：最近一次放大镜的状态。
    var loupeDebugState: DebugLoupeState?
    #endif

    /// 上次用过的选区，按显示器记忆，Tab 恢复。
    static var rememberedSelection: [CGDirectDisplayID: CGRect] = [:]

    /// 遮罩刚出现时，窗口出现在光标之下会送来一次「按住状态」的杂散 mouseDown
    /// （实测 pressedMouseButtons=1）。用一小段静默期挡掉。
    var inputArmedAt: TimeInterval = 0

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
    /// 还没进标注时按 ⌘D：把当前选区（local）原样钉上；裁剪由 Coordinator 从冻结帧里做。
    var onPinSelection: ((CGRect) -> Void)?
    /// 标注默认样式：原地工具栏开出来时用它，改完回报给外部记住。
    var annotationDefaults: AnnotationDefaults = .standard
    var onAnnotationDefaultsChange: ((AnnotationDefaults) -> Void)?
    /// 撤销 / 重做的快捷键（设置页配，默认 ⌘Z / ⇧⌘Z）。
    var editorShortcuts: EditorShortcuts = .standard

    /// 滚动长图期间：遮罩只当取景框（压暗 + 绿框），冻结图与其它装饰全部收起，
    /// 这样用户能看见下面**真实页面在滚**。
    var isScrollCaptureChrome = false

    enum Phase {
        case selecting
        case annotating
    }

    var phase: Phase = .selecting
    /// 是否正处于原地标注阶段（供 Coordinator 判断 Esc 归属）。
    var isAnnotationPhase: Bool { phase == .annotating }

    struct Snapshot {
        let annotations: [Annotation]
        let strokes: [EraserStroke]
        /// 选区也进快照：标注态里能拖边缘改区域，撤销时必须连选区一起回滚，
        /// 否则标注会按旧原点画在新选区上、整体错位。
        let selection: CGRect?
        let restoredBaseImage: CGImage?
        let restoredImageFrame: CGRect?
    }

    var undoStack: [Snapshot] = []
    var redoStack: [Snapshot] = []
    var eraserStrokes: [EraserStroke] = []
    var selectedID: UUID?
    var hoveredAnnotationID: UUID?
    var erasing = false
    var lastErasePoint: CGPoint?

    /// 选择工具下的拖拽类型。
    enum InlineEditDrag {
        case none
        case moving(id: UUID, start: CGPoint, original: Annotation)
        case resizing(id: UUID, handle: ShapeHandle, original: Annotation)
        case rotating(id: UUID, startAngle: CGFloat, original: Annotation)
        case endpoint(id: UUID, handle: ShapeHandle, original: Annotation)
    }

    var inlineEditDrag: InlineEditDrag = .none
    /// 正在编辑的已有文字对象（nil 表示新建）。
    var inlineEditingTextID: UUID?
    let inlineSelectionBorderLayer = CAShapeLayer()
    let inlineHandlesLayer = CAShapeLayer()
    /// 裁剪时底图（正在裁的那张图）的外框。
    let baseFrameBorderLayer = CAShapeLayer()
    var annotations: [Annotation] = []
    var annotationDraft: Annotation?
    /// 选区裁剪出来的原图。标注层按**它的原始分辨率**渲染，所以线 / 箭头不会因为缩放发虚。
    var cropImage: CGImage?
    var liveTextHost: NSView?
    var toolbarModel: InlineToolbarModel?
    var mainToolbarHost: NSView?
    var optionsToolbarHost: NSView?
    var textField: InlineTextField?
    var inlineDragging = false
    var inlineStart: CGPoint = .zero
    var inlineTextOrigin: CGPoint = .zero
    var inlineCounterValue = 1

    let annotationLayer = CALayer()
    /// 从浮窗（钉图或快速访问）恢复时的原图。
    var restoredBaseImage: CGImage?
    var restoredImageFrame: CGRect?
    var cropInitialState: Snapshot?
    /// 这一轮裁剪「正在裁的那张图」的屏幕矩形（见 `cropFrame`）。
    var cropSessionFrame: CGRect?
    let restoredContainerLayer = CALayer()
    let restoredImageLayer = CALayer()

    // MARK: - Layers

    let imageLayer = CALayer()
    let dimLayer = CAShapeLayer()
    let windowHighlightLayer = CAShapeLayer()
    let selectionBorderOuterLayer = CAShapeLayer()
    let selectionBorderInnerLayer = CAShapeLayer()
    let handlesLayer = CAShapeLayer()
    let crosshairLayer = CAShapeLayer()
    let sizeLabelLayer = PillLabelLayer()
    let windowLabelLayer = CATextLayer()
    let hintLayer = CATextLayer()

    var trackingArea: NSTrackingArea?

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

    var isInputArmed: Bool {
        CACurrentMediaTime() >= inputArmedAt
    }

    var canvasBounds: CGRect {
        CGRect(origin: .zero, size: snapshot.screenFrameInPoints.size)
    }

    func requestFocusIfNeeded() {
        guard let window, !window.isKeyWindow else { return }
        onFocusRequest?()
    }

    var isSettled: Bool {
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

    /// 自检用：放大镜卡片的「模型 frame」与「当前呈现 frame」。
    ///
    /// 有隐式动画时两者会不同（呈现值还在半路上）——用来盯住「跟随光标不该有动画」。
    var debugLoupePresentation: (model: CGRect, presentation: CGRect?, isHidden: Bool) {
        (
            model: loupeCardHost?.frame ?? .zero,
            presentation: loupeCardHost?.layer?.presentation()?.frame,
            isHidden: loupeCardHost?.isHidden ?? true
        )
    }

    /// 自检用：放大镜当前取的是哪一块像素、光标落在哪一格。
    struct DebugLoupeState {
        /// 镜面在画布（本显示器 local，原点左下）里的位置。
        let frame: CGRect
        /// 采样窗口在图像里的左上角（图像像素、原点左上）。
        let sourceOrigin: CGPoint
        /// 光标像素（图像像素、原点左上）。
        let cursorPixel: CGPoint
        /// 光标的像素格子在镜面里的位置（左上角为 0）。
        let cell: CGPoint
        /// 当前格子的格边长（point）。
        let cellSide: CGFloat
        /// 取到的颜色。
        let hex: String?
    }

    var debugLoupeState: DebugLoupeState? {
        guard let state = loupeDebugState, !(loupeCardHost?.isHidden ?? true) else { return nil }
        return state
    }

    /// 自检用：吸附预览（窗口描边 + 窗口标签）当前是不是真的画着。
    var debugWindowHighlightVisible: Bool {
        !windowHighlightLayer.isHidden || !windowLabelLayer.isHidden
    }
    #endif

    // MARK: - Region pick 回报

    /// 选区成型且「像样」才值得浮出工具栏（太小的一块按不出来）。
    var isSelectionUsable: Bool {
        guard let selection else { return false }
        return selection.width >= Theme.minimumSelectionSize
            && selection.height >= Theme.minimumSelectionSize
    }

    /// 拖动中重新计时：停住 `regionPickPauseDelay` 就回报「可以出工具栏了」。
    func schedulePauseSignal() {
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
    func firePauseSignal() {
        guard isRegionPickMode, let selection else { return }
        cancelPauseSignal()
        onSelectionPaused?(selection)
    }

    func cancelPauseSignal() {
        pauseWorkItem?.cancel()
        pauseWorkItem = nil
    }

    /// 选区变了（拖动 / 缩放 / 清空）→ 控制条贴着新选框走。
    func notifySelectionChanged() {
        guard isRegionPickMode else { return }
        onSelectionChanged?(selection)
    }

    // MARK: - Layer setup

    func configureLayers() {
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

        configureLoupe()
        updateAllLayers()
    }

    /// 放大镜卡片：一个宿主视图，内容（镜面 + 读数）由 `LoupeReadoutCard` 画。
    ///
    /// 它是本视图的**子视图**（不是图层）：卡片压在冻结图与压暗层之上，跟手移动只改 frame；
    /// 宿主不吃鼠标事件（`PixelLoupeCardHost`），不会挡住框选那一下。
    func configureLoupe() {
        let card = PixelLoupeCardHost(rootView: LoupeReadoutCard(model: loupeCardModel))
        card.translatesAutoresizingMaskIntoConstraints = true
        // 卡片自己有投影，别让宿主把投影裁掉。
        card.layer?.masksToBounds = false
        card.isHidden = true
        addSubview(card)
        loupeCardHost = card
    }

    func configureBorderLayer(_ layer: CAShapeLayer, color: NSColor) {
        layer.fillColor = nil
        layer.strokeColor = color.cgColor
        layer.lineWidth = 1
        layer.isHidden = true
        layer.frame = bounds
    }

    func configurePillTextLayer(_ textLayer: CATextLayer, scale: CGFloat) {
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
        for textLayer in [sizeLabelLayer, windowLabelLayer, hintLayer] {
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

}
