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
            } header: {
                SettingsSectionHeader(title: L10n.generalSectionAppearance)
            }
        }
        .formStyle(.grouped)
    }
}

/// 录屏：系统音频 / 帧率 / 保存位置。
///
/// 保存位置与截图共用（`saveDirectory`）——录下来的东西和截图落在一起最省心。
///
/// @author ixxxxoooo
