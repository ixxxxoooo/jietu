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
                        Button(L10n.permRecheck) { refresh() }
                            .controlSize(.small)
                            .help(L10n.permRecheckHelp)
                    }
                } label: {
                    Text(L10n.permScreenRecording)
                    Text(
                        screenRecordingGranted
                            ? (ScreenCapturePermission.needsRelaunch
                                ? L10n.permScreenRecordingNeedsRelaunch
                                : L10n.permScreenRecordingGranted)
                            : L10n.permScreenRecordingDenied
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
                    Text(L10n.permGrantTarget)
                    Text(L10n.permGrantTargetDesc)
                }

                LabeledContent {
                    // 统一走拖拽授权：打开系统设置并浮出面板，把 App 卡片拖进列表即可。
                    Button(L10n.permDragAuthorize) {
                        triedGranting = true
                        PermissionDragController.shared.present(pane: .screenRecording)
                        refresh()
                    }
                    .help(L10n.permDragAuthorizeHelp)
                } label: {
                    Text(L10n.permGrantAction)
                }

                if suggestsRelaunch {
                    LabeledContent {
                        Button(L10n.permRestartJietu) { ScreenCapturePermission.relaunchApp() }
                    } label: {
                        Text(L10n.permNeedsRelaunch)
                        Text(L10n.permNeedsRelaunchDesc)
                    }
                }
            } header: {
                SettingsSectionHeader(title: L10n.permSectionScreenRecording)
            } footer: {
                // 撤销授权不会从正在跑的进程里收回去：不写清楚，用户会以为「重新检测」坏了。
                Text(L10n.permRecheckStaleHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.lg) {
                        statusLabel(granted: accessibilityGranted)
                        Button(L10n.permRecheck) { refresh() }
                            .controlSize(.small)
                            .help(L10n.permRecheckHelp)
                    }
                } label: {
                    Text(L10n.permAccessibility)
                    Text(
                        accessibilityGranted
                            ? L10n.permAccessibilityGranted
                            : L10n.permAccessibilityDenied
                    )
                }

                LabeledContent {
                    // 与「屏幕录制」保持一致：只留拖拽授权这一个出口，系统设置由面板自己打开。
                    Button(L10n.permDragAuthorize) {
                        PermissionDragController.shared.present(pane: .accessibility)
                        refresh()
                    }
                    .help(L10n.permDragAuthorizeHelp)
                } label: {
                    Text(L10n.permGrantAction)
                }
            } header: {
                SettingsSectionHeader(title: L10n.permSectionAccessibility)
            } footer: {
                Text(L10n.permAccessibilityFooter)
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
            granted ? L10n.permGranted : L10n.permNotGranted,
            systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(granted ? Theme.Colors.success : Theme.Colors.warning)
    }

    private func refresh() {
        let screen = ScreenCapturePermission.isGranted
        if screen != screenRecordingGranted { screenRecordingGranted = screen }
        let ax = AccessibilityPermission.isGranted
        if ax != accessibilityGranted { accessibilityGranted = ax }
    }
}
