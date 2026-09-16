import Observation
import SwiftUI

@Observable
final class OnboardingModel {
    /// 进程启动那一刻是否已有权限。用于判断「刚授权 → 必须重启」。
    let wasGrantedAtLaunch: Bool

    var isGranted: Bool
    var isPolling = false

    private var timer: Timer?

    var needsRelaunch: Bool {
        !wasGrantedAtLaunch && isGranted
    }

    init() {
        let granted = ScreenCapturePermission.isGranted
        self.wasGrantedAtLaunch = granted
        self.isGranted = granted
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

/// 权限引导界面：头部标识 + 状态卡片 + 步骤 + 玻璃按钮。
///
/// 视觉走设计系统：`dialogIcon` 尺寸的品牌字形、`SettingsCard` 状态卡、
/// `GlassButton` 浮动按钮，状态色用 `success` / `warning`。
///
/// @author ixxxxoooo
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            header
            permissionCard
            steps
            Spacer(minLength: 0)
            actions
        }
        .padding(Theme.Spacing.xxl)
        .frame(
            width: Theme.Size.onboarding.width,
            height: Theme.Size.onboarding.height,
            alignment: .topLeading
        )
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: Theme.Size.dialogIcon, weight: .medium))
                .foregroundStyle(Theme.Colors.brand)
                .frame(width: Theme.Size.dialogIcon)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Jietu 需要「屏幕录制」权限")
                    .font(Theme.Typography.title)
                Text("没有它，截图会返回空白画面")
                    .font(Theme.Typography.rowSubtitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var permissionCard: some View {
        SettingsCard(padding: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: model.isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(model.isGranted ? Theme.Colors.success : Theme.Colors.warning)
                Text(model.isGranted ? "已授权" : "未授权")
                    .font(Theme.Typography.bar)
                Spacer(minLength: Theme.Spacing.md)
                if model.needsRelaunch {
                    Text("需重启 Jietu 才会生效")
                        .font(Theme.Typography.rowSubtitle)
                        .foregroundStyle(Theme.Colors.brand)
                }
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            step(1, "点「授权屏幕录制」，在系统弹窗里同意")
            step(2, "若没弹窗，点「打开系统设置」手动勾选 Jietu")
            step(3, "回到这里，点「重启 Jietu」让权限生效")
            Text("macOS 的限制：授权不会对正在运行的进程生效，这一步无法绕过。")
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Text("\(index)")
                .font(Theme.Typography.compactKeyCap.weight(.bold))
                .frame(width: Theme.Size.keyCap, height: Theme.Size.keyCap)
                .background(Circle().fill(Theme.Colors.brand.opacity(0.15)))
                .foregroundStyle(Theme.Colors.brand)
            Text(text)
                .font(Theme.Typography.chip)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.md) {
            if model.isGranted {
                if model.needsRelaunch {
                    GlassButton(
                        title: "重启 Jietu",
                        systemImage: "arrow.clockwise",
                        role: .prominent,
                        isBranded: true
                    ) {
                        ScreenCapturePermission.relaunchApp()
                    }
                }
            } else {
                // 关键：必须先调用这个 API，macOS 才会把 Jietu 注册进
                // 「隐私与安全性 › 屏幕录制」列表，否则用户根本找不到可勾选项。
                GlassButton(
                    title: "授权屏幕录制",
                    systemImage: "lock.shield",
                    role: .prominent,
                    isBranded: true
                ) {
                    if ScreenCapturePermission.request() {
                        model.isGranted = true
                    } else {
                        ScreenCapturePermission.openSystemSettings()
                    }
                }

                GlassButton(title: "打开系统设置", systemImage: "gearshape") {
                    ScreenCapturePermission.openSystemSettings()
                }
            }

            Spacer(minLength: 0)

            GlassButton(
                title: model.isGranted && !model.needsRelaunch ? "完成" : "稍后",
                role: .cancel
            ) {
                onClose()
            }
        }
    }
}
