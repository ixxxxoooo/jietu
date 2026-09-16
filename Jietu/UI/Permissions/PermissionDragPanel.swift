import AppKit
import SwiftUI

/// 拖拽授权面板：浮在系统设置下方，里面是一张可以拖进列表的 App 卡片。
///
/// 不抢焦点（`nonactivatingPanel` 且不成为 key），拖拽开始时切成鼠标穿透，
/// drop 才能落到下面系统设置的那一栏里。
///
/// @author ixxxxoooo
@MainActor
final class PermissionDragPanel: NSPanel {
    private let hostingView: NSHostingView<AnyView>
    private let sizingView: NSHostingView<AnyView>
    private let minimumHeight: CGFloat = 118
    private let screenInset: CGFloat = 12

    init(content: some View) {
        let view = AnyView(content)
        hostingView = NSHostingView(rootView: view)
        sizingView = NSHostingView(rootView: view)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: minimumHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        // 让 setFrame / setContentSize 成为面板几何的唯一来源：
        // 否则 SwiftUI 的 intrinsicContentSize 会在每次布局时把窗口重新撑回去，
        // snap(to:) 定位完立刻被推翻。
        hostingView.sizingOptions = []
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 拖拽时鼠标穿透 + 变淡，drop 才能落到下面的系统设置里。
    func setDraggingPassthrough(_ dragging: Bool) {
        ignoresMouseEvents = dragging
        alphaValue = dragging ? 0.72 : 1
        if dragging {
            orderBack(nil)
        } else {
            orderFrontRegardless()
        }
    }

    /// 贴到系统设置窗口下方：对齐右侧内容区，并夹在当前屏幕的可见范围内。
    func snap(to settingsFrame: CGRect) {
        setFrame(targetFrame(for: settingsFrame), display: false)
        orderFrontRegardless()
    }

    private func targetFrame(for settingsFrame: CGRect) -> CGRect {
        let screen = NSScreen.screens
            .first { $0.frame.intersects(settingsFrame) }?
            .visibleFrame ?? settingsFrame

        // 只贴右侧内容区：左边是侧栏，不是用户要操作的地方。
        let available = max(300, settingsFrame.width - SystemSettingsWindow.sidebarWidth)
        let width = min(available, screen.width - screenInset * 2)
        let height = measuredHeight(for: width)

        var origin = CGPoint(
            x: settingsFrame.minX + SystemSettingsWindow.sidebarWidth,
            y: settingsFrame.minY - height
        )
        origin.x = max(screen.minX + screenInset, min(origin.x, screen.maxX - width - screenInset))
        origin.y = max(screen.minY + screenInset, min(origin.y, screen.maxY - height - screenInset))

        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    /// 按给定宽度量一次内容高度，面板才不会裁掉或留白。
    private func measuredHeight(for width: CGFloat) -> CGFloat {
        sizingView.setFrameSize(NSSize(width: width, height: 4096))
        sizingView.layoutSubtreeIfNeeded()
        return max(minimumHeight, sizingView.fittingSize.height)
    }
}

/// 拖拽授权的总控：打开系统设置 → 浮出面板 → 跟着窗口走 → 窗口关了就收工。
///
/// 用共享实例：入口分散在权限引导、设置页、菜单栏三处，都需要同一个面板。
///
/// @author ixxxxoooo
@MainActor
final class PermissionDragController {
    static let shared = PermissionDragController()

    private var panel: PermissionDragPanel?
    private var timer: Timer?
    /// 拖拽中的状态：兜底用（见 tick）。
    private var isDraggingApp = false
    /// 连续几次找不到系统设置窗口（窗口关了就当收工）。
    private var misses = 0
    private let missLimit = 8

    private init() {}

    var isPresenting: Bool { panel != nil }

    /// 打开「屏幕录制」系统设置，并浮出「把 App 拖进去」的面板。
    func present() {
        // 先申请一次：没问过会弹窗、同时把本 App 注册进列表；被拒过则直接走拖拽授权。
        _ = ScreenCapturePermission.request()
        ScreenCapturePermission.openSystemSettings()
        showPanel()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.close()
        panel = nil
        misses = 0
    }

    private func showPanel() {
        if panel == nil {
            let appURL = Bundle.main.bundleURL
            panel = PermissionDragPanel(
                content: PermissionDragView(
                    appURL: appURL,
                    onOpenSettings: { [weak self] in self?.reopenSettings() },
                    onClose: { [weak self] in self?.close() },
                    onDragStateChange: { [weak self] dragging in
                        self?.isDraggingApp = dragging
                        self?.panel?.setDraggingPassthrough(dragging)
                    }
                )
            )
            panel?.center()
            panel?.orderFrontRegardless()
        }
        startTracking()
    }

    /// 「设置」按钮：URL 在「已经停在这一栏」时是 no-op，所以还要显式激活一次。
    private func reopenSettings() {
        ScreenCapturePermission.openSystemSettings()
        SystemSettingsWindow.activate()
        panel?.orderFrontRegardless()
    }

    private func startTracking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // 定位不需要精度，容差让内核合并掉空闲唤醒。
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        guard let frame = SystemSettingsWindow.frameInCGPoints() else {
            misses += 1
            if misses >= missLimit { close() }
            return
        }
        misses = 0
        panel?.snap(to: SystemSettingsWindow.appKitFrame(fromCG: frame))

        // 兜底：拖拽回调万一没回来（拖到别的 App 上被打断），面板不能卡在鼠标穿透上，
        // 否则里面的按钮全都点不动。
        if !isDraggingApp, let panel, panel.ignoresMouseEvents {
            panel.setDraggingPassthrough(false)
        }
    }
}

/// 面板内容：标题 + 可拖拽的 App 卡片 + 说明。
///
/// 表面走参考项目的**浮动面板玻璃**：静态 `.regular`、`Radius.menuPanel`、不描边
/// （`PopoverMenu` / `NoteSwitcherView` 都是这个配方）；卡片本身是个 `controlSurface`
/// 的「槽」，两边都是 ramp 里的色，没有额外灰。
///
/// @author ixxxxoooo
struct PermissionDragView: View {
    let appURL: URL
    var onOpenSettings: () -> Void
    var onClose: () -> Void
    var onDragStateChange: (Bool) -> Void

    private var appName: String {
        FileManager.default.displayName(atPath: appURL.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            header
            AppBundleDragCard(url: appURL, onDragStateChange: onDragStateChange)
            footer
        }
        .padding(Theme.Spacing.xl)
        .glassPanel()
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Colors.accent)
            Text("把 \(appName) 拖进右边的列表")
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.md)
            // 系统设置被别的东西挡住时，用它拉回前台。
            BarIconButton(
                title: "把系统设置拉到前面",
                systemImage: "gearshape",
                action: onOpenSettings
            )
            BarIconButton(
                title: "关闭",
                systemImage: "xmark",
                tint: Theme.Colors.textTertiary,
                action: onClose
            )
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Text("那一栏是接受拖入的：拖进去就等于把它加进列表并授权。")
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            GlassButton(
                title: "重启 Jietu",
                systemImage: "arrow.clockwise",
                role: .prominent,
                action: { ScreenCapturePermission.relaunchApp() }
            )
            .help("授权后需要重启才会生效")
        }
    }
}
