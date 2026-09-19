import AppKit
import Combine
import SwiftUI

struct HotkeysSettingsPane: View {
    @Bindable var settings: SettingsStore
    var onHotkeyChange: (HotkeyAction, Hotkey?) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HotkeyRecorderView(
                        title: action.title,
                        subtitle: action.subtitle,
                        hotkey: binding(for: action)
                    )
                }
            } header: {
                SettingsSectionHeader(title: L10n.hotkeysSectionGlobal)
            } footer: {
                Text(L10n.hotkeysSectionGlobalFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                ForEach(EditorShortcut.allCases) { shortcut in
                    HotkeyRecorderView(
                        title: shortcut.title,
                        subtitle: shortcut.subtitle,
                        hotkey: editorBinding(for: shortcut)
                    )
                }
                Button(L10n.hotkeysResetDefault) { settings.resetEditorShortcuts() }
                    .disabled(settings.editorShortcuts == .standard)
            } header: {
                SettingsSectionHeader(title: L10n.hotkeysSectionEditor)
            } footer: {
                Text(L10n.hotkeysSectionEditorFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for action: HotkeyAction) -> Binding<Hotkey?> {
        Binding(
            get: { settings.hotkey(for: action) },
            set: { newValue in
                settings.setHotkey(newValue, for: action)
                onHotkeyChange(action, newValue)
            }
        )
    }

    private func editorBinding(for shortcut: EditorShortcut) -> Binding<Hotkey?> {
        Binding(
            get: { settings.editorShortcuts.hotkey(for: shortcut) },
            set: { newValue in
                var updated = settings.editorShortcuts
                updated.set(newValue, for: shortcut)
                settings.editorShortcuts = updated
            }
        )
    }
}

/// 浮窗：停靠位置 / 自动关闭。
///
/// @author ixxxxoooo
