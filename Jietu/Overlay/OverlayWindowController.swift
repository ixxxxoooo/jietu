import AppKit

final class OverlayWindowController {
    let window: OverlayWindow
    let snapshot: DisplaySnapshot
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

    #if DEBUG
    var debugSelection: CGRect? { canvas.debugSelection }
    #endif

    init(
        snapshot: DisplaySnapshot,
        session: CaptureSession,
        screen: NSScreen,
        displayIndex: Int,
        displayCount: Int,
        inlineMode: Bool,
        annotationDefaults: AnnotationDefaults = .standard
    ) {
        self.snapshot = snapshot
        canvas = OverlayCanvasView(
            snapshot: snapshot,
            session: session,
            displayIndex: displayIndex,
            displayCount: displayCount
        )
        canvas.inlineMode = inlineMode
        canvas.annotationDefaults = annotationDefaults

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
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(canvas)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}
