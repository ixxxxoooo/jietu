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
        case 0: return "欢迎使用 \(AppIdentity.displayName)"
        case 1: return "屏幕录制权限"
        case 2: return "设一个快捷键"
        default: return "一切就绪"
        }
    }

    private var subtitle: String {
        switch step {
        case 0: return "截完即复制、可标注、可保存，全部在本机完成。"
        case 1: return model.isGranted
            ? "已经拿到权限，可以正常截图了。" : "没有它，截图会返回空白画面。"
        case 2: return "不设也能截图，从菜单栏开始就行。"
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
            return "按 \(hotkey.displayString) 随时开始区域截图。"
        }
        return "随时可以从菜单栏开始截图。"
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
                    title: "截图后自动复制到剪贴板",
                    subtitle: "截完直接去别的 App 粘贴。",
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
                    title: "登录时启动",
                    subtitle: "开机后随菜单栏常驻。",
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
            caption("这两项随时可以在设置里改。")
        }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            OnboardingCard {
                OnboardingRow(
                    title: "屏幕录制",
                    subtitle: model.isGranted
                        ? (model.needsRelaunch ? "已经勾选，重启后生效。" : "Jietu 可以正常冻结屏幕并截图。")
                        : "没有它，截图会返回空白画面。",
                    systemImage: "camera.viewfinder",
                    tint: model.isGranted ? Theme.Colors.success : Theme.Colors.accent
                ) {
                    OnboardingStatusBadge(
                        title: model.isGranted ? "已授权" : "未授权",
                        systemImage: model.isGranted
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: model.isGranted ? Theme.Colors.success : Theme.Colors.warning
                    )
                }
                OnboardingDivider()
                OnboardingRow(
                    title: "授权对象",
                    subtitle: "在「系统设置 › 隐私与安全性 › 屏幕录制」里勾选它；列表里没有就点「+」手动添加。",
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
                        title: "需要重启",
                        subtitle: "macOS 的限制：授权只在授权之后启动的进程里生效。",
                        systemImage: "arrow.clockwise",
                        tint: Theme.Colors.warning
                    ) {
                        Button("重启 Jietu") { ScreenCapturePermission.relaunchApp() }
                            .controlSize(.small)
                    }
                }
            }
            HStack(spacing: Theme.Spacing.md) {
                caption(
                    model.suggestsRelaunch
                        ? "已经勾选却还是未授权？点「重启 Jietu」立刻生效。"
                        : "列表里找不到本 App 时，点系统设置那一栏左下的「+」手动添加。"
                )
                Spacer(minLength: 0)
                Button("重新检测") { model.refresh() }
                    .buttonStyle(.link)
                    .font(.caption)
                // 列表里根本看不到本 App 时的出口：清掉旧记录再重新注册一次。
                Button("重新注册…") { model.reRegisterPermission() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("清掉「屏幕录制」里的旧记录并重新申请，让它重新出现在系统设置的列表里")
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
            caption("默认都不绑定，避免和系统或其它 App 抢组合键。")
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            OnboardingCard {
                OnboardingRow(
                    title: "从菜单栏开始",
                    subtitle: "区域 / 窗口 / 全屏 / 定时 / 滚动长图都在那里。",
                    systemImage: "menubar.rectangle",
                    tint: Theme.Colors.accent
                )
                OnboardingDivider()
                OnboardingRow(
                    title: "设置里还有更多",
                    subtitle: "保存位置与格式、预览浮窗、标注默认样式。",
                    systemImage: "gearshape",
                    tint: Theme.Colors.textSecondary
                )
            }
            caption("按 ⌘, 或点菜单栏的「偏好设置…」随时打开设置。")
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
                        Label("上一步", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if showsSkip {
                    Button("稍后") { advance() }
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
        case 0: return "继续"
        case 1:
            if model.isGranted { return model.needsRelaunch ? "重启 Jietu" : "继续" }
            return "授权屏幕录制"
        case 2: return "继续"
        default: return "开始使用"
        }
    }

    private func primaryAction() {
        switch step {
        case 1 where !model.isGranted:
            model.requestAccess()
        case 1 where model.needsRelaunch:
            ScreenCapturePermission.relaunchApp()
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
    }

    /// 点「授权屏幕录制」：先走系统申请（只在没问过时弹窗），没弹窗就直接把人送到系统设置。
    func requestAccess() {
        hasTriedGranting = true
        if ScreenCapturePermission.request() {
            refresh()
        } else {
            ScreenCapturePermission.openSystemSettings()
            // 人切去系统设置期间窗口还在，回来时轮询会接上。
            refresh()
        }
    }

    /// 「重新注册…」：清掉本 App 在「屏幕录制」里的旧记录，再重新申请一次。
    func reRegisterPermission() {
        hasTriedGranting = true
        ScreenCapturePermission.reRegister()
        ScreenCapturePermission.openSystemSettings()
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
