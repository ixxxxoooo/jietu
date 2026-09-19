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
                SettingsSectionHeader(title: "全局热键")
            } footer: {
                Text(
                    "默认都不设置快捷键，点一下录制器再按组合键即可录入；"
                        + "悬停录制器时右侧的 ✕ 可清除。\n"
                        + "全局热键会抢占其它 App 的同名组合键，建议避开常用组合。"
                )
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
                Button("恢复默认（⌘Z / ⇧⌘Z）") { settings.resetEditorShortcuts() }
                    .disabled(settings.editorShortcuts == .standard)
            } header: {
                SettingsSectionHeader(title: "标注编辑")
            } footer: {
                Text(
                    "只在标注编辑器里生效（原地编辑与独立窗口都算），不占用系统级组合键，"
                        + "所以默认就配好：⌘Z 撤销、⇧⌘Z 重做，也可以改成别的。\n"
                        + "这与上面那组全局热键是两回事——把 ⌘Z 设成全局会抢掉其它 App 的撤销。"
                )
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
