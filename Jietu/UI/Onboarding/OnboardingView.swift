import AppKit
import Observation
import SwiftUI

/// 首次启动的引导向导：欢迎 → 屏幕录制权限 → 快捷键 → 完成。
///
/// 排版照参考项目的 Onboarding：`hero`（图标 / 字形 + 标题 + 副标题）→ `OnboardingCard`
/// 里的若干行 → 底部（步骤圆点 + 上一步 / 稍后 / 主按钮）；顶部的 sheen 渐变延伸到标题栏下，
/// 每一步的高度报给窗口，窗口跟着长，不裁不撑。
///
/// @author ixxxxoooo
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var onClose: () -> Void
    /// 每步量到的理想高度，交给窗口自适应。
    var onHeightChange: (CGFloat) -> Void = { _ in }

    static let width: CGFloat = 520
    /// 只用于第一次布局前的窗口尺寸。
    static let initialSize = CGSize(width: width, height: 352)

    @State private var step = 0

    private static let lastStep = 3

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            hero
            stepContent
            footer
        }
        // 顶部留少一点：标题栏本身还有 32pt，得让开红绿灯。
        .padding(.top, Theme.Spacing.xs)
        .padding([.horizontal, .bottom], Theme.Spacing.xxl)
        .frame(maxWidth: .infinity)
        // 用理想高度而不是窗口高度，尺寸收敛才不会互相喂。
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            onHeightChange($0)
        }
        // 只有渐变伸到标题栏下，内容留在安全区。
        .background(
            LinearGradient(
                colors: [Theme.Colors.sheen, Color.clear],
                startPoint: .top, endPoint: .center
            )
            .ignoresSafeArea()
        )
        .animation(.easeInOut(duration: 0.2), value: step)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: Theme.Spacing.md) {
            heroMark
            VStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(.title2.weight(.bold))
                Text(subtitle)
                    .font(Theme.Typography.chip)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var heroMark: some View {
        if step == 0 {
            Image(nsImage: Self.appIcon)
                .resizable()
                .frame(width: 60, height: 60)
        } else {
            Image(systemName: heroSymbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(heroTint)
                .frame(width: 60, height: 60)
                .background(Circle().fill(heroTint.opacity(0.14)))
        }
    }

    private var title: String {
        switch step {
        case 0: return L10n.onboardingWelcome(AppIdentity.displayName)
        case 1: return L10n.onboardingScreenRecordingPerm
        case 2: return L10n.onboardingSetHotkey
        default: return L10n.onboardingAllReady
        }
    }

    private var subtitle: String {
        switch step {
        case 0: return L10n.onboardingWelcomeSubtitle
        case 1:
            if model.isGranted {
                if model.needsRelaunch { return L10n.onboardingPermNeedsRelaunchSubtitle }
                return L10n.onboardingPermGrantedSubtitle
            }
            return L10n.onboardingPermDeniedSubtitle
        case 2: return L10n.onboardingHotkeySubtitle
        default: return readyMessage
        }
    }

    /// 每一步一个自己的字形：权限用取景框、快捷键用键盘、完成才是对勾，
    /// 不然「权限」在已授权时会和「完成」长得一模一样。
    private var heroSymbol: String {
        switch step {
        case 1: return "camera.viewfinder"
        case 2: return "keyboard"
        default: return "checkmark"
        }
    }

    private var heroTint: Color {
        switch step {
        case 1: return model.isGranted ? Theme.Colors.success : Theme.Colors.accent
        case 2: return Theme.Colors.warning
        default: return Theme.Colors.success
        }
    }

    private var readyMessage: String {
        if let hotkey = model.areaCaptureHotkey {
            return L10n.onboardingReadyWithHotkey(hotkey.displayString)
        }
        return L10n.onboardingReadyFromMenu
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: welcomeStep
        case 1: permissionStep
        case 2: hotkeyStep
        default: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            OnboardingCard {
                OnboardingRow(
                    title: L10n.onboardingCopyToClipboard,
                    subtitle: L10n.onboardingCopyToClipboardDesc,
                    systemImage: "doc.on.clipboard",
                    tint: Theme.Colors.accent
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.copyToClipboard },
                        set: { model.copyToClipboard = $0 }
                    ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                OnboardingDivider()
                OnboardingRow(
                    title: L10n.onboardingLaunchAtLogin,
                    subtitle: L10n.onboardingLaunchAtLoginDesc,
                    systemImage: "power",
                    tint: Theme.Colors.success
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.launchAtLogin = $0 }
                    ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            caption(L10n.onboardingChangeInSettings)
        }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            OnboardingCard {
                OnboardingRow(
                    title: L10n.onboardingScreenRecording,
                    subtitle: model.isGranted
                        ? (model.needsRelaunch
                            ? L10n.permScreenRecordingNeedsRelaunch
                            : L10n.permScreenRecordingGranted)
                        : L10n.permScreenRecordingDenied,
                    systemImage: "camera.viewfinder",
                    tint: model.isGranted ? Theme.Colors.success : Theme.Colors.accent
                ) {
                    permissionBadge(granted: model.isGranted)
                }
                OnboardingDivider()
                OnboardingRow(
                    title: L10n.onboardingAccessibility,
                    subtitle: model.isAccessibilityGranted
                        ? L10n.onboardingAccessibilityGranted
                        : L10n.onboardingAccessibilityDenied,
                    systemImage: "hand.tap",
                    tint: model.isAccessibilityGranted ? Theme.Colors.success : Theme.Colors.accent
                ) {
                    permissionBadge(granted: model.isAccessibilityGranted)
                }
                OnboardingDivider()
                OnboardingRow(
                    title: L10n.onboardingGrantTarget,
                    subtitle: L10n.onboardingGrantTargetDesc,
                    systemImage: "app.badge.checkmark",
                    tint: Theme.Colors.accent
                ) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(AppIdentity.displayName)
                            .font(Theme.Typography.bar)
                        if AppIdentity.isDevChannel {
                            DevChannelBadge()
                        }
                    }
                }
                if model.suggestsRelaunch {
                    OnboardingDivider()
                    OnboardingRow(
                        title: L10n.onboardingRelaunchNeeded,
                        subtitle: L10n.onboardingRelaunchDesc,
                        systemImage: "arrow.clockwise",
                        tint: Theme.Colors.warning
                    ) {
                        Button(L10n.permRestartJietu) { ScreenCapturePermission.relaunchApp() }
                            .controlSize(.small)
                    }
                }
            }
            HStack(spacing: Theme.Spacing.md) {
                caption(permissionCaption)
                Spacer(minLength: 0)
                Button(L10n.permRecheck) { model.refresh() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            OnboardingCard {
                ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element) { index, action in
                    if index > 0 {
                        OnboardingDivider()
                    }
                    OnboardingRow(
                        title: action.title,
                        subtitle: action.subtitle,
                        systemImage: action.symbol,
                        tint: Theme.Colors.accent
                    ) {
                        HotkeyRecorderChip(hotkey: hotkeyBinding(for: action))
                    }
                }
            }
            caption(L10n.onboardingNoHotkeyHint)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            OnboardingCard {
                OnboardingRow(
                    title: L10n.onboardingFromMenuBar,
                    subtitle: L10n.onboardingFromMenuBarDesc,
                    systemImage: "menubar.rectangle",
                    tint: Theme.Colors.accent
                )
                OnboardingDivider()
                OnboardingRow(
                    title: L10n.onboardingMoreInSettings,
                    subtitle: L10n.onboardingMoreInSettingsDesc,
                    systemImage: "gearshape",
                    tint: Theme.Colors.textSecondary
                )
            }
            caption(L10n.onboardingSettingsHint)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(0...Self.lastStep, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.primary : Color.primary.opacity(0.2))
                        .frame(width: 7, height: 7)
                }
            }
            HStack {
                if step > 0 {
                    Button {
                        step -= 1
                    } label: {
                        Label(L10n.onboardingPrevious, systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if showsSkip {
                    Button(L10n.onboardingLater) { advance() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var showsSkip: Bool {
        step == 1 || step == 2
    }

    private var primaryTitle: String {
        switch step {
        case 0: return L10n.onboardingContinue
        case 1:
            if !model.isGranted { return L10n.onboardingAuthorize }
            if model.needsRelaunch { return L10n.permRestartJietu }
            // 屏幕录制齐了、辅助功能还没授权：这一格就是它的「去授权」。
            // 位置和屏幕录制那颗完全一致（右下角主按钮），不放行内、也不挤在「重新检测」旁边。
            if !model.isAccessibilityGranted { return L10n.onboardingAuthorizeAccessibility }
            return L10n.onboardingContinue
        case 2: return L10n.onboardingContinue
        default: return L10n.onboardingStart
        }
    }

    private func primaryAction() {
        switch step {
        case 1 where !model.isGranted:
            model.requestAccess()
        case 1 where model.needsRelaunch:
            ScreenCapturePermission.relaunchApp()
        case 1 where !model.isAccessibilityGranted:
            model.requestAccessibilityAccess()
        case Self.lastStep:
            onClose()
        default:
            advance()
        }
    }

    private func advance() {
        step = min(step + 1, Self.lastStep)
    }

    // MARK: - Shared bits

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Theme.Spacing.xs)
    }

    /// 卡片下那行小字：按当前状态挑一句最有用的话。
    ///
    /// 已经授权、也不需要重启时**不**讲「把卡片拖进列表」——那时候那句话是废话；
    /// 换成「撤销授权要重启才看得出来」，正好回答「我在系统设置里删了，怎么还显示已授权」。
    private var permissionCaption: String {
        if model.suggestsRelaunch { return L10n.onboardingRelaunchHint }
        return model.isGranted ? L10n.permRecheckStaleHint : L10n.onboardingDragHint
    }

    /// 权限行右侧的状态标识。两种权限、两种情况都走这一份：
    /// 只要各家自己拼，就迟早会一边是「未授权」药丸、一边是「去授权」按钮。
    private func permissionBadge(granted: Bool) -> OnboardingStatusBadge {
        OnboardingStatusBadge(
            title: granted ? L10n.permGranted : L10n.permNotGranted,
            systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            tint: granted ? Theme.Colors.success : Theme.Colors.warning
        )
    }

    private func hotkeyBinding(for action: HotkeyAction) -> Binding<Hotkey?> {
        Binding(
            get: { model.hotkey(for: action) },
            set: { model.setHotkey($0, for: action) }
        )
    }

    /// 直接从 bundle 读图标：LaunchServices 注册之前 `NSApp.applicationIconImage` 还是通用图标。
    private static let appIcon: NSImage = {
        if let name = Bundle.main.infoDictionary?["CFBundleIconFile"] as? String,
            let url = Bundle.main.url(forResource: name, withExtension: "icns"),
            let image = NSImage(contentsOf: url)
        {
            return image
        }
        return NSApp.applicationIconImage
    }()
}

/// 权限引导的状态：实时状态 + 1 秒轮询 + App 重新激活时复查。
///
/// 为什么不做启动时快照：用户去系统设置勾完再回来，快照还停在「未授权」，
/// 界面和截图入口就会一直说没权限。参考项目的做法也是「每次读活值 + 轮询」。
///
/// @author ixxxxoooo
@Observable
final class OnboardingModel {
    var isGranted: Bool
    var isAccessibilityGranted: Bool
    var isPolling = false
    /// 这次会话里是否已经引导过授权（点了「授权屏幕录制」或打开过系统设置）。
    ///
    /// 用过之后如果状态还是「未授权」，多半是 macOS 不刷新进程内状态，
    /// 这时要给出「重启 Jietu」这个出口。
    var hasTriedGranting = false

    private let settings: SettingsStore

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// 授权晚于本次启动：已勾选，但当前进程用不了。
    var needsRelaunch: Bool { ScreenCapturePermission.needsRelaunch }

    /// 该不该给「重启 Jietu」这个出口。
    var suggestsRelaunch: Bool {
        needsRelaunch || (hasTriedGranting && !isGranted)
    }

    /// 引导页里要读写的设置（先落到设置里，向导结束后设置页能直接接着用）。
    var copyToClipboard: Bool {
        get { settings.copyToClipboard }
        set { settings.copyToClipboard = newValue }
    }

    var launchAtLogin: Bool {
        get { settings.launchAtLogin }
        set {
            settings.launchAtLogin = newValue
            LaunchAtLogin.setEnabled(newValue)
        }
    }

    var areaCaptureHotkey: Hotkey? { settings.hotkey(for: .areaCapture) }

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        self.isGranted = ScreenCapturePermission.isGranted
        self.isAccessibilityGranted = AccessibilityPermission.isGranted
    }

    func hotkey(for action: HotkeyAction) -> Hotkey? { settings.hotkey(for: action) }

    func setHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) {
        settings.setHotkey(hotkey, for: action)
    }

    /// 现读一次授权状态（「重新检测」按钮走这里）。
    func refresh() {
        let granted = ScreenCapturePermission.isGranted
        if granted != isGranted {
            isGranted = granted
        }
        let axGranted = AccessibilityPermission.isGranted
        if axGranted != isAccessibilityGranted {
            isAccessibilityGranted = axGranted
        }
    }

    /// 点「授权屏幕录制」：打开系统设置并浮出拖拽面板（那一栏会接受把 .app 拖进去）。
    func requestAccess() {
        hasTriedGranting = true
        PermissionDragController.shared.present(pane: .screenRecording)
        refresh()
    }

    /// 点「授权辅助功能」：打开系统设置辅助功能面板并浮出拖拽面板。
    func requestAccessibilityAccess() {
        PermissionDragController.shared.present(pane: .accessibility)
        refresh()
    }

    func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // 从系统设置切回来时能立刻更新，不用等下一次 tick。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        isPolling = false
    }
}
