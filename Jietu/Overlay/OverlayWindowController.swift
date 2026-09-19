import AppKit

final class OverlayWindowController {
    let window: OverlayWindow
    let snapshot: DisplaySnapshot
    let screen: NSScreen
    private let canvas: OverlayCanvasView

    var onCancel: (() -> Void)? {
        get { canvas.onCancel }
        set { canvas.onCancel = newValue }
    }

    var onCommit: ((CGRect) -> Void)? {
        get { canvas.onCommit }
        set { canvas.onCommit = newValue }
    }

    /// 原地标注确认后的最终图 + 选区。
    var onCommitAnnotated: ((CGImage, CGRect) -> Void)? {
        get { canvas.onCommitAnnotated }
        set { canvas.onCommitAnnotated = newValue }
    }

    /// 滚动长图起步：选区不急着交付，鼠标停住就回报（由控制条接手）。
    var isRegionPickMode: Bool {
        get { canvas.isRegionPickMode }
        set { canvas.isRegionPickMode = newValue }
    }

    /// 窗口截图模式（直接选窗截图，也可按空格在框选与选窗之间切换）。
    var isWindowOnlyMode: Bool {
        get { canvas.isWindowOnlyMode }
        set { canvas.isWindowOnlyMode = newValue }
    }

    /// 单击窗口选定事件。
    var onWindowSelected: ((WindowInfo) -> Void)? {
        get { canvas.onWindowSelected }
        set { canvas.onWindowSelected = newValue }
    }

    /// 鼠标在选区上停住（或松手）→ 选区 local 矩形。
    var onSelectionPaused: ((CGRect) -> Void)? {
        get { canvas.onSelectionPaused }
        set { canvas.onSelectionPaused = newValue }
    }

    /// 录屏模式（框好区域 / 点窗口就开录）。
    var isRecordMode: Bool {
        get { canvas.isRecordMode }
        set { canvas.isRecordMode = newValue }
    }

    var onRecordRegionPicked: ((CGRect) -> Void)? {
        get { canvas.onRecordRegionPicked }
        set { canvas.onRecordRegionPicked = newValue }
    }

    /// 就地编辑工具栏里选了「手动 / 自动滚动」（参数二是选区，本显示器 local 矩形）。
    var onScrollCapture: ((ScrollingCaptureSession.Mode, CGRect) -> Void)? {
        get { canvas.onScrollCapture }
        set { canvas.onScrollCapture = newValue }
    }

    /// 选区被拖 / 缩放 / 清空（nil）。
    var onSelectionChanged: ((CGRect?) -> Void)? {
        get { canvas.onSelectionChanged }
        set { canvas.onSelectionChanged = newValue }
    }

    /// 是否正在原地标注（Esc 归属判断）。
    var isInlineEditing: Bool { canvas.isAnnotationPhase }

    /// 原地工具栏「下载 / 钉图」。
    var onSaveImage: ((CGImage) -> Void)? {
        get { canvas.onSaveImage }
        set { canvas.onSaveImage = newValue }
    }
    var onPinImage: ((CGImage, CGRect) -> Void)? {
        get { canvas.onPinImage }
        set { canvas.onPinImage = newValue }
    }

    /// 原地标注的样式变更（工具 / 颜色 / 参数），由 Coordinator 转给外部记住。
    var onAnnotationDefaultsChange: ((AnnotationDefaults) -> Void)? {
        get { canvas.onAnnotationDefaultsChange }
        set { canvas.onAnnotationDefaultsChange = newValue }
    }

    /// 本遮罩覆盖的显示器 AppKit 全局范围，用来判断鼠标落在哪块屏。
    var screenFrame: CGRect { window.frame }

    func focus() {
        window.makeKey()
        window.makeFirstResponder(canvas)
    }

    /// 从浮窗恢复居中原地编辑。
    func restoreImageForInlineEditing(_ image: CGImage) {
        canvas.restoreImageForInlineEditing(image)
    }

    #if DEBUG
    var debugSelection: CGRect? { canvas.debugSelection }

    /// 自检用：吸附预览（窗口描边 + 标签）是否画着。
    var debugWindowHighlightVisible: Bool { canvas.debugWindowHighlightVisible }

    /// 自检用：展开就地工具栏的「滚动截图」选项 / 直接选模式。
    @discardableResult
    func debugOpenScrollOptions() -> Bool { canvas.debugOpenScrollOptions() }

    /// 自检用：等价于点一下工具栏的「录屏」。
    func debugTriggerRecord() -> Bool { canvas.debugTriggerRecord() }

    @discardableResult
    func debugTriggerScrollCapture(_ mode: ScrollingCaptureSession.Mode) -> Bool {
        canvas.debugTriggerScrollCapture(mode)
    }

    /// 自检用：直接送一对合成事件进遮罩（不经注入管线，见 `OverlayCoordinator.debugClick`）。
    ///
    /// - Parameter appKitPoint: AppKit 全局坐标。
    @discardableResult
    func debugClick(atAppKitPoint appKitPoint: CGPoint) -> Bool {
        let inWindow = window.convertFromScreen(
            NSRect(origin: appKitPoint, size: .zero)
        ).origin
        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: 1
            ),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: inWindow, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1,
                pressure: 0
            )
        else { return false }
        canvas.mouseDown(with: down)
        canvas.mouseUp(with: up)
        return true
    }
    #endif

    init(
        snapshot: DisplaySnapshot,
        session: CaptureSession,
        screen: NSScreen,
        displayIndex: Int,
        displayCount: Int,
        inlineMode: Bool,
        allowsCrop: Bool = false,
        annotationDefaults: AnnotationDefaults = .standard,
        editorShortcuts: EditorShortcuts = .standard
    ) {
        self.snapshot = snapshot
        self.screen = screen
        canvas = OverlayCanvasView(
            snapshot: snapshot,
            session: session,
            displayIndex: displayIndex,
            displayCount: displayCount
        )
        canvas.inlineMode = inlineMode
        canvas.allowsCrop = allowsCrop
        canvas.annotationDefaults = annotationDefaults
        canvas.editorShortcuts = editorShortcuts

        // 注意：不要用 `NSWindow(contentRect:...screen:)` 直接传 screen.frame。
        // 实测在缩放/副屏上 AppKit 会把原点乘以 backingScale（523 → 1046），
        // 尺寸却不变，导致遮罩跑到屏幕外。先建成零尺寸再 setFrame 才是可靠的。
        window = OverlayWindow(
            contentRect: NSRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.setFrame(screen.frame, display: false)
        window.contentView = canvas
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isMovable = false
        window.animationBehavior = .none
        // 必须高于主菜单 / 通知中心，才能真的盖住菜单栏和 Dock。
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        window.hidesOnDeactivate = false

        canvas.onFocusRequest = { [weak self] in
            self?.focus()
        }
    }

    func show() {
        // 300ms 静默期：躲开窗口出现瞬间的杂散鼠标事件。
        canvas.armInput(after: 0.3)
        // 一上来就把鼠标所在窗口点亮（压暗层的洞口），不是整屏先糊一层。
        canvas.primeHoveredWindow()
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(canvas)
    }

    #if DEBUG
    /// 自检用：跳过鼠标直接摆一个选区。
    func debugSetSelection(_ localRect: CGRect) {
        canvas.debugSetSelection(localRect)
    }

    /// 自检用：放大镜的模型 / 呈现 frame。
    var debugLoupePresentation: (model: CGRect, presentation: CGRect?, isHidden: Bool) {
        canvas.debugLoupePresentation
    }

    /// 自检用：放大镜当前采样窗口 / 光标格子。
    var debugLoupeState: OverlayCanvasView.DebugLoupeState? {
        canvas.debugLoupeState
    }
    #endif

    /// 滚动长图：遮罩留在原地当取景框，但**鼠标穿透**，滚轮落到下面那个页面。
    func enterScrollCaptureChrome() {
        canvas.setScrollCaptureChrome(true)
        // 取景框要「看见下面真实页面在滚」：窗口必须真的透明。
        // 冻结图一收起，不透明窗口就只剩黑底——用户会以为黑屏崩了，手动模式也没法滚。
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}
