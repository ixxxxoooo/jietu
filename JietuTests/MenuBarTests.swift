import AppKit
import Carbon.HIToolbox
import Testing
@testable import Jietu

@Suite("菜单栏与权限授权项")
struct MenuBarTests {

    @Test("菜单栏构建包含屏幕录制与辅助功能的拖拽授权菜单项")
    @MainActor
    func menuBarContainsAuthorizationItems() {
        let menuBar = MenuBarController()
        menuBar.refresh()
        let menu = menuBar.menuForTesting

        let titles = menu.items.map(\.title)
        #expect(titles.contains { $0.contains("拖拽授权「屏幕录制」") })
        #expect(titles.contains { $0.contains("拖拽授权「辅助功能」") })
        #expect(titles.contains { $0.contains("屏幕录制权限：") })
        #expect(titles.contains { $0.contains("辅助功能权限：") })
    }

    @Test("点击拖拽授权「辅助功能」触发 onAuthorizeAccessibility 回调")
    @MainActor
    func authorizeAccessibilityActionTriggered() {
        let menuBar = MenuBarController()
        var callbackCalled = false
        menuBar.onAuthorizeAccessibility = {
            callbackCalled = true
        }

        let menu = menuBar.menuForTesting
        guard let item = menu.items.first(where: { $0.title.contains("拖拽授权「辅助功能」") }) else {
            Issue.record("未找到辅助功能拖拽授权菜单项")
            return
        }

        #expect(item.action != nil)
        #expect(item.target != nil)
        if let target = item.target, let action = item.action {
            _ = target.perform(action, with: item)
        }
        #expect(callbackCalled == true)
    }

    @Test("区域 / 窗口 / 全屏三个录制入口平铺在顶层（与截图同一列，中间一条分隔线），各走各的回调")
    @MainActor
    func recordingMenuItemsAreDistinct() {
        let menuBar = MenuBarController()
        var fired: [String] = []
        menuBar.onRecordRegion = { fired.append("region") }
        menuBar.onRecordWindow = { fired.append("window") }
        menuBar.onRecordFullScreen = { fired.append("fullScreen") }

        let menu = menuBar.menuForTesting
        // 两家族都平铺在顶层，中间**只用一条分隔线**隔开（不收起子菜单）。
        #expect(!menu.items.contains { $0.title == "截图" && $0.submenu != nil })
        #expect(!menu.items.contains { $0.title == "录制" && $0.submenu != nil })
        let head = menu.items.prefix(9).map { $0.isSeparatorItem ? "———" : $0.title }
        #expect(
            Array(head) == [
                "区域截图", "窗口截图", "全屏截图", "定时截图", "滚动长图…",
                "———",
                "区域录制", "窗口录制", "全屏录制",
            ],
            "截图与录制该是相邻两组，中间一条分隔线"
        )

        let want = ["区域录制", "窗口录制", "全屏录制"]
        for title in want {
            guard let item = menu.items.first(where: { $0.title == title }) else {
                Issue.record("菜单里没有「\(title)」")
                continue
            }
            #expect(item.target != nil)
            if let target = item.target, let action = item.action {
                _ = target.perform(action, with: item)
            }
        }
        #expect(fired == ["region", "window", "fullScreen"])
    }

    @Test("配了快捷键的菜单项显示快捷键，没配的什么都不显示")
    @MainActor
    func menuShowsConfiguredHotkeysOnly() {
        let menuBar = MenuBarController()
        // 只给「区域截图」配一个 ⌘⇧1，别的都不配。
        // 故意不传 menuKeyEquivalent：老数据就是这样（这个字段之前录的热键没有），
        // 菜单得靠键码把「1」推出来——用户报的正是这条。
        let configured = Hotkey(
            keyCode: UInt32(kVK_ANSI_1),
            carbonModifiers: UInt32(cmdKey | shiftKey)
        )
        menuBar.hotkeyProvider = { action in action == .areaCapture ? configured : nil }
        menuBar.refresh()

        func item(_ title: String) -> NSMenuItem? {
            menuBar.menuForTesting.items.first { $0.title == title }
        }
        let area = item("区域截图")
        #expect(area?.keyEquivalent == "1")
        #expect(area?.keyEquivalentModifierMask == [.command, .shift])

        for title in ["窗口截图", "全屏截图", "滚动长图…", "区域录制", "窗口录制", "全屏录制"] {
            #expect(item(title)?.keyEquivalent == "", "\(title) 没配快捷键，就不该显示")
            #expect(item(title)?.keyEquivalentModifierMask == [])
        }

        // 清掉配置再刷一次：显示跟着变。
        menuBar.hotkeyProvider = { _ in nil }
        menuBar.refresh()
        #expect(item("区域截图")?.keyEquivalent == "")
    }

    @Test("点击拖拽授权「屏幕录制」触发 onAuthorizeScreenRecording 回调")
    @MainActor
    func authorizeScreenRecordingActionTriggered() {
        let menuBar = MenuBarController()
        var callbackCalled = false
        menuBar.onAuthorizeScreenRecording = {
            callbackCalled = true
        }

        let menu = menuBar.menuForTesting
        guard let item = menu.items.first(where: { $0.title.contains("拖拽授权「屏幕录制」") }) else {
            Issue.record("未找到屏幕录制拖拽授权菜单项")
            return
        }

        #expect(item.action != nil)
        #expect(item.target != nil)
        if let target = item.target, let action = item.action {
            _ = target.perform(action, with: item)
        }
        #expect(callbackCalled == true)
    }

    @Test("OnboardingModel 追踪并能刷新辅助功能权限状态")
    @MainActor
    func onboardingModelTracksAccessibility() {
        let model = OnboardingModel()
        #expect(model.isAccessibilityGranted == AccessibilityPermission.isGranted)
        model.refresh()
        #expect(model.isAccessibilityGranted == AccessibilityPermission.isGranted)
    }

    @Test("截图历史合并到最近截图：主菜单保留最近截图且二级子菜单承载预览卡片")
    @MainActor
    func recentCapturesMergedWithHistory() {
        let menuBar = MenuBarController()
        menuBar.refresh()
        let menu = menuBar.menuForTesting

        let titles = menu.items.map(\.title)
        #expect(titles.contains("最近截图"))
        #expect(!titles.contains { $0.contains("截图历史") })

        guard let recentItem = menu.items.first(where: { $0.title == "最近截图" }) else {
            Issue.record("未找到「最近截图」菜单项")
            return
        }
        #expect(recentItem.submenu != nil)

        let testItem = HistoryItem(
            id: "test-id",
            date: Date(),
            image: NSImage(size: NSSize(width: 100, height: 100)),
            url: nil,
            cgImage: nil
        )
        menuBar.historyItemsProvider = { [testItem] }

        // 触发菜单更新
        menuBar.menuNeedsUpdate(menuBar.recentMenuForTesting)
        let recentMenu = menuBar.recentMenuForTesting
        #expect(recentMenu.items.count == 1)
        #expect(recentMenu.items.first?.view is MenuHostingView<RecentHistoryMenuView>)
    }

    @Test("没有最近截图时，「最近截图」子菜单是一条原生灰字项（不再是一大块白卡片）")
    @MainActor
    func emptyRecentMenuFallsBackToNativeItem() {
        let menuBar = MenuBarController()
        menuBar.historyItemsProvider = { [] }
        menuBar.menuNeedsUpdate(menuBar.recentMenuForTesting)

        let recentMenu = menuBar.recentMenuForTesting
        #expect(recentMenu.items.count == 1)
        let only = recentMenu.items[0]
        #expect(only.title == "暂无最近截图")
        #expect(only.isEnabled == false)
        #expect(only.view == nil, "空状态不该再塞那张 320pt 宽的卡片视图")

        // 有截图时才换成卡片（原来那套）。
        let item = HistoryItem(
            id: "only", date: Date(), image: NSImage(size: NSSize(width: 100, height: 100)),
            url: nil, cgImage: nil
        )
        menuBar.historyItemsProvider = { [item] }
        menuBar.menuNeedsUpdate(recentMenu)
        #expect(recentMenu.items.first?.view is MenuHostingView<RecentHistoryMenuView>)
    }

    @Test("最近截图子菜单高度根据截图条数动态扩展且受屏幕限制")
    @MainActor
    func recentMenuHeightDynamicallyScales() {
        // 0 张图：紧凑空状态
        let h0 = MenuBarController.calculateRecentMenuHeight(for: [])
        #expect(h0 == 130)

        func makeItem(_ id: String) -> HistoryItem {
            HistoryItem(
                id: id,
                date: Date(),
                image: NSImage(size: NSSize(width: 1920, height: 1080)),
                url: nil,
                cgImage: nil
            )
        }

        // 1 张图：约 200~230pt
        let h1 = MenuBarController.calculateRecentMenuHeight(for: [makeItem("1")])
        #expect(h1 > 200 && h1 < 250)

        // 2 张图：比 1 张图显著增高
        let h2 = MenuBarController.calculateRecentMenuHeight(for: [makeItem("1"), makeItem("2")])
        #expect(h2 > h1)

        // 4 张图：能够放得下 4 张图（高度随条目递增）
        let items4 = (1...4).map { makeItem("\($0)") }
        let h4 = MenuBarController.calculateRecentMenuHeight(for: items4)
        #expect(h4 > h2)

        // 大量图（20张）：受屏幕最大可用高度限制，不超出屏幕
        let items20 = (1...20).map { makeItem("\($0)") }
        let h20 = MenuBarController.calculateRecentMenuHeight(for: items20)
        let screenMax = max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 90)
        #expect(h20 <= screenMax)
    }
}


