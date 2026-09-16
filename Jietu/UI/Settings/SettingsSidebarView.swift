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
                icon(for: item)
            }
            .tag(item)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// 未选中 → 强调色图标；选中 → **不给颜色**，交给系统。
    ///
    /// 选中底色的强调程度有两种：侧栏拿到焦点时是强调蓝（图标必须变白），
    /// 没焦点时是浅灰（图标必须是标签色）。哪一种只有系统知道，
    /// 自己写死任何一种都会在另一种情况下看不见。
    @ViewBuilder
    private func icon(for item: SettingsSection) -> some View {
        if navigation.section == item {
            Image(systemName: item.symbol)
        } else {
            Image(systemName: item.symbol)
                .foregroundStyle(Theme.Colors.icon)
        }
    }

    /// `List` 只认可选选中值；路由回 `select` 以便记录历史。
    private var selection: Binding<SettingsSection?> {
        Binding(
            get: { navigation.section },
            set: { if let section = $0 { navigation.select(section) } }
        )
    }
}
