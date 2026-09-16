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
                        ? "Jietu 可以正常冻结屏幕并截图。" : "没有它，截图会返回空白画面。",
                    systemImage: "camera.viewfinder",
                    tint: Theme.Colors.accent
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
                    subtitle: "在「系统设置 › 隐私与安全性 › 屏幕录制」里勾选它。",
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
                if model.needsRelaunch {
                    OnboardingDivider()
                    OnboardingRow(
                        title: "需要重启",
                        subtitle: "macOS 的限制：授权不会对正在运行的进程生效。",
                        systemImage: "arrow.clockwise",
                        tint: Theme.Colors.warning
                    ) {
                        Button("重启") { ScreenCapturePermission.relaunchApp() }
                            .controlSize(.small)
                    }
                }
            }
            caption("可以点「稍后」跳过，之后再从菜单栏的「权限…」进来。")
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
            // 关键：必须先调用这个 API，macOS 才会把本 App 注册进
            // 「隐私与安全性 › 屏幕录制」列表，否则用户根本找不到可勾选项。
            if ScreenCapturePermission.request() {
                model.isGranted = true
            } else {
                ScreenCapturePermission.openSystemSettings()
            }
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

/// 权限状态的轮询。
///
/// @author ixxxxoooo
@Observable
final class OnboardingModel {
    /// 进程启动那一刻是否已有权限。用于判断「刚授权 → 必须重启」。
    let wasGrantedAtLaunch: Bool

    var isGranted: Bool
    var isPolling = false

    private let settings: SettingsStore

    private var timer: Timer?

    var needsRelaunch: Bool {
        !wasGrantedAtLaunch && isGranted
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
        let granted = ScreenCapturePermission.isGranted
        self.settings = settings
        self.wasGrantedAtLaunch = granted
        self.isGranted = granted
    }

    func hotkey(for action: HotkeyAction) -> Hotkey? { settings.hotkey(for: action) }

    func setHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) {
        settings.setHotkey(hotkey, for: action)
    }

    func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let granted = ScreenCapturePermission.isGranted
                if granted != self.isGranted {
                    self.isGranted = granted
                }
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        isPolling = false
    }
}
