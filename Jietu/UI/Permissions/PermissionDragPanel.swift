import AppKit
import SwiftUI

/// 拖拽授权面板：贴在系统设置窗口下面，并跟它**同一层级**，里面是一张可以拖进列表的 App 卡片。
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
    /// 当前贴着的系统设置窗口，排序以它为基准（`snap(to:)` 时更新）。
    private var settingsWindowNumber: CGWindowID?

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

        // `NSPanel` 默认是 `.floating`，那会浮在**所有**普通窗口之上——
        // 别的窗口盖住系统设置时，面板还杵在最前面。层级交给 `snap(to:)` 跟系统设置对齐。
        level = .normal
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
        // 拖动时沉到系统设置窗口下面（仍与它同层），拖完浮回它正上方。
        guard let number = settingsWindowNumber else {
            dragging ? orderBack(nil) : orderFrontRegardless()
            return
        }
        order(dragging ? .below : .above, relativeTo: Int(number))
    }

    /// 贴到系统设置窗口下方：对齐右侧内容区，夹进当前屏幕可见范围，并排到该窗口正上方。
    ///
    /// 层级跟着系统设置走、排序以它的 windowNumber 为基准，所以**盖上系统设置的窗口
    /// 也会盖住本面板**（不会像 `.floating` 那样浮在最前面）。
    func snap(to target: SystemSettingsWindow.Target) {
        level = NSWindow.Level(rawValue: target.level)
        settingsWindowNumber = target.windowNumber
        setFrame(targetFrame(for: target.appKitFrame), display: false)
        order(.above, relativeTo: Int(target.windowNumber))
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

    /// 当前正在引导的面板（面板文案 / 打开哪一栏都跟着它）。
    private var currentPane: PermissionPane = .screenRecording

    var isPresenting: Bool { panel != nil }

    /// 打开指定的隐私面板，并浮出「把 App 拖进去」的面板。
    ///
    /// - Parameter pane: 屏幕录制 / 辅助功能；默认屏幕录制（保持既有调用点不变）。
    func present(pane: PermissionPane = .screenRecording) {
        if isPresenting && currentPane != pane {
            close()
        }
        currentPane = pane
        if pane == .screenRecording {
            _ = ScreenCapturePermission.request()
        } else if pane == .accessibility {
            _ = AccessibilityPermission.request()
        }
        pane.openSystemSettings()
        // URL 在「系统设置已经停在这一栏」时是 no-op，再显式激活一次把它拉到前台。
        SystemSettingsWindow.activate()
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
            let pane = currentPane
            panel = PermissionDragPanel(
                content: PermissionDragView(
                    appURL: appURL,
                    pane: pane,
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
        guard let target = SystemSettingsWindow.target() else {
            misses += 1
            if misses >= missLimit { close() }
            return
        }
        misses = 0
        // 拖拽中不碰几何和层级：`snap` 会把面板重新排到系统设置**上方**，正好推翻
        // 拖拽时的「沉下去 + 鼠标穿透」，drop 目标也会跟着重算——拖到一半把窗口挪了，
        // 是拖拽最容易白拖的一种方式。松手后再跟上去就行（0.4s 一轮，看不出来）。
        if !isDraggingApp {
            panel?.snap(to: target)
        }

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
    /// 正在引导的面板：决定说明文案。
    var pane: PermissionPane = .screenRecording
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
            Text(L10n.dragPanelInstruction(appName))
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.md)
            BarIconButton(
                title: L10n.dragPanelClose,
                systemImage: "xmark",
                tint: Theme.Colors.textTertiary,
                action: onClose
            )
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(pane.dragHint)
                    .font(Theme.Typography.rowSubtitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 那一行已经在列表里的时候，单靠拖拽是没用的（拖不出第二行），
                // 得先把旧记录删掉——这正是「拖进去还不生效」的来路。
                Text(L10n.dragPanelStaleRow)
                    .font(Theme.Typography.compactKeyCap)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            GlassButton(
                title: L10n.dragPanelRestart,
                systemImage: "arrow.clockwise",
                role: .prominent,
                action: { ScreenCapturePermission.relaunchApp() }
            )
            .help(L10n.dragPanelRestartHelp)
        }
    }
}
