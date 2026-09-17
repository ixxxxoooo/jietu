import SwiftUI

/// 设置详情列：按当前分区渲染对应面板。
///
/// 背景交给窗口材质（`contentBackground`），并把滚动背景藏起来，
/// 这样 `Form(.grouped)` 的卡片浮在窗口材质上，和系统设置一致。
///
/// @author ixxxxoooo
struct SettingsDetailView: View {
    @Bindable var settings: SettingsStore
    @Bindable var navigation: SettingsNavigationState
    var onHotkeyChange: (HotkeyAction, Hotkey?) -> Void

    var body: some View {
        Group {
            switch navigation.section {
            case .general:
                GeneralSettingsPane(settings: settings)
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
                AboutSettingsPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectView(material: .contentBackground, blending: .behindWindow)
                .ignoresSafeArea()
        )
        .scrollContentBackground(.hidden)
    }
}
