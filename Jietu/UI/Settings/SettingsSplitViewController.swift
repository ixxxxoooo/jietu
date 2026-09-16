import AppKit
import SwiftUI

/// 真正的 `NSSplitViewController`。
///
/// 只有它能让侧栏拿到系统 sidebar 材质（`sidebarWithViewController:`），
/// 也才能让工具栏用上 `.sidebarTrackingSeparator`；SwiftUI 的 `NavigationSplitView`
/// 两者都拿不到，材质会不对。
///
/// @author ixxxxoooo
@MainActor
final class SettingsSplitViewController: NSSplitViewController {
    init(sidebar: some View, detail: some View) {
        super.init(nibName: nil, bundle: nil)

        let sidebarHost = NSHostingController(rootView: sidebar)
        // 窗口尺寸由窗口说了算，不让 SwiftUI 的 fitting size 反过来撑窗口。
        sidebarHost.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = Theme.Size.settingsSidebar
        sidebarItem.maximumThickness = Theme.Size.settingsSidebar
        sidebarItem.canCollapse = false

        let detailHost = NSHostingController(rootView: detail)
        detailHost.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = Theme.Size.settingsDetailMinimum

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
