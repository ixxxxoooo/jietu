import AppKit
import QuartzCore

/// 钉图边框光晕：钉图外圈一圈选区绿的光。
///
/// 光晕**另开一层透明窗口**，而不是画进钉图自己——光晕要落在钉图窗口外面，
/// 而钉图内容视图是 `masksToBounds` 裁圆角的，画进去会被裁掉。
/// 光晕窗作为钉图的 child window 挂在它**下面**：child window 会跟着父窗移动，
/// 但不会跟着父窗改大小，所以缩放另由 `PinPanel.onFrameChanged` 通知同步。
///
/// @author ixxxxoooo
final class PinGlowController {
    /// 光晕向外扩出的宽度：钉图窗口每边都留这么多给光晕。
    ///
    /// 要够宽：余晖得在这段距离里淡到零，否则会在光晕窗口边缘被生生切断，
    /// 看着就是一个绿框而不是一圈光。
    static let margin: CGFloat = 26

    /// 钉图窗口 frame → 光晕窗口 frame（每边外扩 `margin`）。
    static func glowFrame(for pinFrame: CGRect) -> CGRect {
        pinFrame.insetBy(dx: -margin, dy: -margin)
    }

    private let glowWindow: NSWindow
    private weak var pinWindow: NSWindow?

    /// 给钉图挂上光晕。调用方要把钉图自己的系统阴影关掉——光晕本身就是一圈发光，叠着会发灰。
    init(pinWindow: NSWindow) {
        self.pinWindow = pinWindow
        let frame = Self.glowFrame(for: pinWindow.frame)
        let glowWindow = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        glowWindow.contentView = PinGlowView(frame: NSRect(origin: .zero, size: frame.size))
        glowWindow.isOpaque = false
        glowWindow.backgroundColor = .clear
        glowWindow.hasShadow = false
        // 只负责发光，不接鼠标：钉图的拖动 / 缩放照旧落在钉图窗口上。
        glowWindow.ignoresMouseEvents = true
        glowWindow.isReleasedWhenClosed = false
        glowWindow.animationBehavior = .none
        glowWindow.hidesOnDeactivate = false
        glowWindow.level = pinWindow.level
        glowWindow.collectionBehavior = pinWindow.collectionBehavior
        self.glowWindow = glowWindow

        pinWindow.addChildWindow(glowWindow, ordered: .below)
    }

    /// 钉图 frame 变了（拖动 / 缩放 / 恢复实际大小）：光晕窗口跟着挪 + 改大小。
    func syncFrame(forPinFrame pinFrame: NSRect) {
        glowWindow.setFrame(Self.glowFrame(for: pinFrame), display: true)
    }

    /// 关钉图时调用：先摘掉 child window 再收起来，否则钉图没了光晕还留在屏上。
    func detach() {
        pinWindow?.removeChildWindow(glowWindow)
        glowWindow.orderOut(nil)
    }

    /// 测试用：光晕窗口当前的 frame。
    var frameForTesting: NSRect { glowWindow.frame }

    /// 测试用：光晕窗口是不是还在钉图的 child windows 里。
    var isAttachedForTesting: Bool {
        pinWindow?.childWindows?.contains { $0 === glowWindow } ?? false
    }

    /// 测试用：光晕窗口是否吃鼠标事件。
    var ignoresMouseEventsForTesting: Bool { glowWindow.ignoresMouseEvents }

    /// 测试用：光晕窗口是不是还在屏上。
    var isVisibleForTesting: Bool { glowWindow.isVisible }

    /// 测试用：光晕窗口的内容视图（离屏渲染看画出来的颜色）。
    var contentViewForTesting: NSView? { glowWindow.contentView }
}

/// 只画光晕的一层视图：贴着边缘一圈亮线 + 两层向外衰减的柔光。
///
/// 两层柔光是为了「贴边亮、快速淡掉」这个观感：一层窄而亮负责贴边那一圈，
/// 一层宽而淡负责余晖；只有一层时要么糊一大片、要么根本看不出光。
///
/// @author ixxxxoooo
private final class PinGlowView: NSView {
    /// 贴着图片边缘那圈亮线的宽度。
    private static let ringWidth: CGFloat = 1.5
    /// 贴边柔光（窄、亮）。
    private static let innerBloomRadius: CGFloat = 7
    private static let innerBloomOpacity: Float = 0.7
    /// 余晖（宽、淡）。
    private static let outerBloomRadius: CGFloat = 18
    private static let outerBloomOpacity: Float = 0.28

    private let outerBloomLayer = CAShapeLayer()
    private let innerBloomLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        let green = NSColor(Theme.selectionGreen).cgColor

        // 柔光：整块内区填绿，靠自己的阴影往外发散（内区被钉图窗口盖住，只看得到外面那圈）。
        configureBloom(outerBloomLayer, color: green,
                       radius: Self.outerBloomRadius, opacity: Self.outerBloomOpacity)
        configureBloom(innerBloomLayer, color: green,
                       radius: Self.innerBloomRadius, opacity: Self.innerBloomOpacity)

        // 亮线：贴着图片边缘的硬边，光晕不至于是一圈没边界的糊。
        ringLayer.fillColor = nil
        ringLayer.strokeColor = green
        ringLayer.lineWidth = Self.ringWidth
        layer?.addSublayer(ringLayer)

        updatePaths()
    }

    private func configureBloom(_ shape: CAShapeLayer, color: CGColor, radius: CGFloat, opacity: Float) {
        shape.fillColor = color
        shape.shadowColor = color
        shape.shadowOffset = .zero
        shape.shadowRadius = radius
        shape.shadowOpacity = opacity
        layer?.insertSublayer(shape, at: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 光晕的几何全在图层路径里，**不能只靠 `layout()`**：
    /// 这个视图没有子视图也没有约束，AppKit 的布局流程不保证会走到 `layout()`
    /// （实测真机上就没走，窗口全透明、光晕一个像素都看不见）。
    /// 所以初始化与每次改尺寸都自己刷一遍。
    private func updatePaths() {
        let inner = bounds.insetBy(dx: PinGlowController.margin, dy: PinGlowController.margin)
        let path = CGPath(
            roundedRect: inner,
            cornerWidth: PinGeometry.defaultCornerRadius,
            cornerHeight: PinGeometry.defaultCornerRadius,
            transform: nil
        )
        for shape in [outerBloomLayer, innerBloomLayer, ringLayer] {
            shape.frame = bounds
            shape.path = path
        }
        outerBloomLayer.shadowPath = path
        innerBloomLayer.shadowPath = path
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePaths()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePaths()
    }

    override func layout() {
        super.layout()
        updatePaths()
    }
}
