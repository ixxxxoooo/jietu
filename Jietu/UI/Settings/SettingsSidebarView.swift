import SwiftUI

/// 设置侧栏：stock `.sidebar` 列表。
///
/// 图标统一 `Theme.Colors.icon`（来自 `AccentColor`），不逐项换色。
/// `.scrollContentBackground(.hidden)` 让 `NSSplitViewItem` 的 sidebar 材质透上来。
///
/// @author ixxxxoooo
struct SettingsSidebarView: View {
    @Bindable var navigation: SettingsNavigationState

    var body: some View {
        List(SettingsSection.allCases, selection: selection) { item in
            Label {
                Text(item.title)
            } icon: {
                Image(systemName: item.symbol)
                    .foregroundStyle(Theme.Colors.icon)
            }
            .tag(item)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// `List` 只认可选选中值；路由回 `select` 以便记录历史。
    private var selection: Binding<SettingsSection?> {
        Binding(
            get: { navigation.section },
            set: { if let section = $0 { navigation.select(section) } }
        )
    }
}
