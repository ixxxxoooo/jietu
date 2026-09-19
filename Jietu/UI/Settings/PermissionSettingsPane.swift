import AppKit
import Combine
import SwiftUI

struct PermissionSettingsPane: View {
    @State private var screenRecordingGranted = ScreenCapturePermission.isGranted
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    @State private var triedGranting = false

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// 授权晚于本次启动，或引导过授权但状态还没变 → 给「重启」。
    private var suggestsRelaunch: Bool {
        ScreenCapturePermission.needsRelaunch || (triedGranting && !screenRecordingGranted)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.lg) {
                        statusLabel(granted: screenRecordingGranted)
                        Button("重新检测") { refresh() }
                            .controlSize(.small)
                            .help("立刻再读一次系统里的授权状态")
                    }
                } label: {
                    Text("屏幕录制")
                    Text(
                        screenRecordingGranted
                            ? (ScreenCapturePermission.needsRelaunch
                                ? "已经勾选，重启后生效。" : "Jietu 可以正常冻结屏幕并截图。")
                            : "没有它，截图会返回空白画面。"
                    )
                }

                // dev 渠道是独立 bundle id，系统设置里是另一条授权，得让用户知道勾哪个。
                LabeledContent {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(AppIdentity.displayName)
                        if AppIdentity.isDevChannel {
                            DevChannelBadge()
                        }
                    }
                } label: {
                    Text("授权对象")
                    Text(
                        "在「系统设置 › 隐私与安全性 › 屏幕录制」里勾选它；"
                            + "若列表里没有它，点列表左下的「+」手动选中这个 App。"
                    )
                }

                LabeledContent {
                    // 统一走拖拽授权：打开系统设置并浮出面板，把 App 卡片拖进列表即可。
                    Button("拖拽授权…") {
                        triedGranting = true
                        PermissionDragController.shared.present(pane: .screenRecording)
                        refresh()
                    }
                    .help("打开系统设置并浮出面板，把本 App 的卡片拖进列表")
                } label: {
                    Text("授权操作")
                }

                if suggestsRelaunch {
                    LabeledContent {
                        Button("重启 Jietu") { ScreenCapturePermission.relaunchApp() }
                    } label: {
                        Text("需要重启")
                        Text("macOS 的限制：授权只在授权之后启动的进程里生效。")
                    }
                }
            } header: {
                SettingsSectionHeader(title: "屏幕录制")
            }

            Section {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.lg) {
                        statusLabel(granted: accessibilityGranted)
                        Button("重新检测") { refresh() }
                            .controlSize(.small)
                            .help("立刻再读一次系统里的授权状态")
                    }
                } label: {
                    Text("辅助功能")
                    Text(
                        accessibilityGranted
                            ? "「滚动长图（自动滚动）」可以合成滚轮了。"
                            : "「滚动长图（自动滚动）」需要它来合成滚轮事件；不授权也能用手动滚动。"
                    )
                }

                LabeledContent {
                    // 与「屏幕录制」保持一致：只留拖拽授权这一个出口，系统设置由面板自己打开。
                    Button("拖拽授权…") {
                        PermissionDragController.shared.present(pane: .accessibility)
                        refresh()
                    }
                    .help("打开系统设置并浮出面板，把本 App 的卡片拖进列表")
                } label: {
                    Text("授权操作")
                }
            } header: {
                SettingsSectionHeader(title: "辅助功能")
            } footer: {
                Text(
                    "授权状态每秒复查一次，从系统设置切回来会立刻更新；"
                        + "辅助功能授权是**现读**的，不用重启。\n"
                        + "自签名 / Debug 构建有时不会自动出现在系统设置的列表里"
                        + "（但授权本身照样生效），用「拖拽授权…」把本 App 拖进去即可。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in refresh() }
    }

    private func statusLabel(granted: Bool) -> some View {
        Label(
            granted ? "已授权" : "未授权",
            systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(granted ? Color.green : Color.orange)
    }

    private func refresh() {
        let screen = ScreenCapturePermission.isGranted
        if screen != screenRecordingGranted { screenRecordingGranted = screen }
        let ax = AccessibilityPermission.isGranted
        if ax != accessibilityGranted { accessibilityGranted = ax }
    }
}
