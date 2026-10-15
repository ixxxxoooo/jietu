import SwiftUI

/// 设置详情列：按当前分区渲染对应面板。
///
/// 背景交给窗口自己（系统设置同款）：`Form(.grouped)` 的分组卡片直接浮在窗口背景上，
/// 工具栏与侧栏的玻璃由 `NSSplitViewController` / `NSToolbar` 提供。
///
/// @author ixxxxoooo
struct SettingsDetailView: View {
    @Bindable var settings: SettingsStore
    @Bindable var navigation: SettingsNavigationState
    var updates: UpdateManager
    var onHotkeyChange: (HotkeyAction, Hotkey?) -> Void

    var body: some View {
        Group {
            switch navigation.section {
            case .general:
                GeneralSettingsPane(settings: settings)
            case .appearance:
                AppearanceSettingsPane(settings: settings)
            case .capture:
                CaptureSettingsPane(settings: settings)
            case .hotkeys:
                HotkeysSettingsPane(settings: settings, onHotkeyChange: onHotkeyChange)
            case .quickAccess:
                QuickAccessSettingsPane(settings: settings)
            case .recording:
                RecordingSettingsPane(settings: settings)
            case .annotation:
                AnnotationSettingsPane(settings: settings)
            case .permission:
                PermissionSettingsPane()
            case .about:
                AboutSettingsPane(updates: updates)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
