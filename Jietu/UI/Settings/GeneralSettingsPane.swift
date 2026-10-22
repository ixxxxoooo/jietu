import AppKit
import Combine
import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var settings: SettingsStore
    /// 系统那一侧是不是把 Jietu 的通知关掉了。
    ///
    /// 我们这边的开关说了不算：系统设置 › 通知 里没允许，保存后就是一条都不出，
    /// 而且**完全无声**——用户只会觉得「勾了没用」。所以这里读一次真状态并直说。
    @State private var systemNotificationsDenied = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.launchAtLogin) {
                    Text(L10n.generalLaunchAtLogin)
                    Text(L10n.generalLaunchAtLoginDesc)
                }
                Toggle(isOn: $settings.playShutterSound) {
                    Text(L10n.generalPlayShutterSound)
                    Text(L10n.generalPlayShutterSoundDesc)
                }
                Toggle(isOn: $settings.copyToClipboard) {
                    Text(L10n.generalCopyToClipboard)
                    Text(L10n.generalCopyToClipboardDesc)
                }
                Toggle(isOn: $settings.showSaveNotification) {
                    Text(L10n.generalShowNotification)
                    Text(L10n.generalShowNotificationDesc)
                }
                .onChange(of: settings.showSaveNotification) { _, enabled in
                    if enabled {
                        CaptureNotifier.requestAuthorizationShared()
                    }
                    // 授权请求是异步的，等一下再读状态，让系统有时间处理。
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        refreshNotificationAuthorization()
                    }
                }
                if settings.showSaveNotification && systemNotificationsDenied {
                    LabeledContent {
                        Button(L10n.generalOpenNotificationSettings) {
                            CaptureNotifier.openSystemNotificationSettings()
                        }
                    } label: {
                        Text(L10n.generalNotificationDenied)
                        Text(L10n.generalNotificationDeniedDesc)
                    }
                }
            } header: {
                SettingsSectionHeader(title: L10n.generalSectionGeneral)
            } footer: {
                Text(L10n.generalDefaultBehaviorFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshNotificationAuthorization)
        // 用户可能刚去系统设置里改过，切回来要立刻反映。
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshNotificationAuthorization()
        }
    }

    /// 读一次系统的通知授权状态，决定要不要把「系统里被关掉了」那行提示亮出来。
    private func refreshNotificationAuthorization() {
        Task { @MainActor in
            systemNotificationsDenied = await CaptureNotifier.currentAuthorization() == .denied
        }
    }
}

/// 录屏：系统音频 / 帧率 / 保存位置。
///
/// 保存位置与截图共用（`saveDirectory`）——录下来的东西和截图落在一起最省心。
///
/// @author ixxxxoooo
