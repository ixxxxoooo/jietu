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

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            permissionRow
            Divider()
            explanation
            Spacer(minLength: 0)
            actions
        }
        .padding(24)
        .frame(width: 520, height: 380, alignment: .topLeading)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("Jietu 需要「屏幕录制」权限")
                    .font(.system(size: 17, weight: .semibold))
                Text("没有它，截图会返回空白画面")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(model.isGranted ? Color.green : Color.orange)
            Text(model.isGranted ? "已授权" : "未授权")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            if model.needsRelaunch {
                Text("需重启 Jietu 才会生效")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, "点「授权屏幕录制」，在系统弹窗里同意")
            step(2, "若没弹窗，点「打开系统设置」手动勾选 Jietu")
            step(3, "回到这里，点「重启 Jietu」让权限生效")
            Text("macOS 的限制：授权不会对正在运行的进程生效，这一步无法绕过。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.brand.opacity(0.15)))
                .foregroundStyle(Theme.brand)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if model.isGranted {
                if model.needsRelaunch {
                    Button("重启 Jietu") {
                        ScreenCapturePermission.relaunchApp()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                }
            } else {
                // 关键：必须先调用这个 API，macOS 才会把 Jietu 注册进
                // 「隐私与安全性 › 屏幕录制」列表，否则用户根本找不到可勾选项。
                Button("授权屏幕录制") {
                    if ScreenCapturePermission.request() {
                        model.isGranted = true
                    } else {
                        ScreenCapturePermission.openSystemSettings()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)

                Button("打开系统设置") {
                    ScreenCapturePermission.openSystemSettings()
                }
            }

            Spacer()

            Button(model.isGranted && !model.needsRelaunch ? "完成" : "稍后") {
                onClose()
            }
        }
    }
}
