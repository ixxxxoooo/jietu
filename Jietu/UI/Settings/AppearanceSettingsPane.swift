import SwiftUI

/// 外观设置：主题 / 语言 / 钉图边框光晕。
///
/// @author ixxxxoooo
struct AppearanceSettingsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
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
                SettingsSectionHeader(title: L10n.appearanceSectionInterface)
            }

            Section {
                Toggle(isOn: $settings.pinBorderGlow) {
                    Text(L10n.appearancePinBorderGlow)
                    Text(L10n.appearancePinBorderGlowDesc)
                }
            } header: {
                SettingsSectionHeader(title: L10n.appearanceSectionPin)
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
