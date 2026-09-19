import AppKit
import Combine
import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var settings: SettingsStore

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
                }
            } header: {
                SettingsSectionHeader(title: L10n.generalSectionGeneral)
            } footer: {
                Text(L10n.generalDefaultBehaviorFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                } label: {
                    Text(L10n.generalTheme)
                    Text(L10n.generalThemeDesc)
                }
                .onChange(of: settings.appearance) { _, newValue in
                    newValue.apply()
                }

                Picker(selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                } label: {
                    Text(L10n.generalLanguage)
                    Text(L10n.generalLanguageDesc)
                }
                .onChange(of: settings.language) { _, _ in
                    promptLanguageRelaunch()
                }
            } header: {
                SettingsSectionHeader(title: L10n.generalSectionAppearance)
            }
        }
        .formStyle(.grouped)
    }

    /// 语言切换后菜单栏 / 已打开窗口仍握着旧文案，提示并重启即可全量生效。
    private func promptLanguageRelaunch() {
        let alert = NSAlert()
        alert.messageText = L10n.languageRestartTitle
        alert.informativeText = L10n.languageRestartBody
        alert.addButton(withTitle: L10n.languageRestartNow)
        alert.addButton(withTitle: L10n.languageRestartLater)
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenCapturePermission.relaunchApp()
        }
    }
}

/// 录屏：系统音频 / 帧率 / 保存位置。
///
/// 保存位置与截图共用（`saveDirectory`）——录下来的东西和截图落在一起最省心。
///
/// @author ixxxxoooo
