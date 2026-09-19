import AppKit
import Carbon.HIToolbox
import Testing
@testable import Jietu

// 断言一律走 `L10n`，不写死中文文案：菜单标题本身就是 L10n 出来的，
// 写死的话测试只在中文环境下通过（CI 是英文环境，会整片红）。
@Suite("菜单栏与权限授权项")
struct MenuBarTests {

    @Test("菜单栏构建包含屏幕录制与辅助功能的拖拽授权菜单项")
    @MainActor
    func menuBarContainsAuthorizationItems() {
        let menuBar = MenuBarController()
        menuBar.refresh()
        let menu = menuBar.menuForTesting

        let titles = menu.items.map(\.title)
        #expect(titles.contains { $0.contains(L10n.menuDragAuthorizeScreenRecording) })
        #expect(titles.contains { $0.contains(L10n.menuDragAuthorizeAccessibility) })
        // 权限状态项的文字跟当前授权状态走，两种都算「在」。
        let screenRecordingTitles = [true, false].map { L10n.menuScreenRecordingPermission(granted: $0) }
        let accessibilityTitles = [true, false].map { L10n.menuAccessibilityPermission(granted: $0) }
        #expect(titles.contains { screenRecordingTitles.contains($0) })
        #expect(titles.contains { accessibilityTitles.contains($0) })
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
        guard let item = menu.items.first(where: { $0.title.contains(L10n.menuDragAuthorizeAccessibility) }) else {
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

    @Test("菜单里有「取色器」，点它走 onPickColor")
    @MainActor
    func colorPickerMenuItemTriggersCallback() {
        let menuBar = MenuBarController()
        var callbackCalled = false
        menuBar.onPickColor = {
            callbackCalled = true
        }

        let menu = menuBar.menuForTesting
        guard let item = menu.items.first(where: { $0.title == L10n.menuColorPicker }) else {
            Issue.record("未找到取色器菜单项")
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
        // 「截图」「录制」是分组名、本来就不该作为菜单项存在，所以这两条是反向断言，
        // 跟语言无关（任何语言下都不该出现），保留字面量即可。
        #expect(!menu.items.contains { $0.title == "截图" && $0.submenu != nil })
        #expect(!menu.items.contains { $0.title == "录制" && $0.submenu != nil })
        let head = menu.items.prefix(10).map { $0.isSeparatorItem ? "———" : $0.title }
        #expect(
            Array(head) == [
                L10n.menuAreaCapture, L10n.menuWindowCapture, L10n.menuFullScreenCapture,
                L10n.menuTimedCapture, L10n.menuScrollingCapture, L10n.menuColorPicker,
                "———",
                L10n.menuRegionRecording, L10n.menuWindowRecording, L10n.menuFullScreenRecording,
            ],
            "截图（含滚动长图 / 取色器）与录制该是相邻两组，中间一条分隔线"
        )

        let want = [L10n.menuRegionRecording, L10n.menuWindowRecording, L10n.menuFullScreenRecording]
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
        let area = item(L10n.menuAreaCapture)
        #expect(area?.keyEquivalent == "1")
        #expect(area?.keyEquivalentModifierMask == [.command, .shift])

        let unconfigured = [
            L10n.menuWindowCapture, L10n.menuFullScreenCapture, L10n.menuScrollingCapture,
            L10n.menuRegionRecording, L10n.menuWindowRecording, L10n.menuFullScreenRecording,
        ]
        for title in unconfigured {
            #expect(item(title)?.keyEquivalent == "", "\(title) 没配快捷键，就不该显示")
            #expect(item(title)?.keyEquivalentModifierMask == [])
        }

        // 清掉配置再刷一次：显示跟着变。
        menuBar.hotkeyProvider = { _ in nil }
        menuBar.refresh()
        #expect(item(L10n.menuAreaCapture)?.keyEquivalent == "")
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
        guard let item = menu.items.first(where: { $0.title.contains(L10n.menuDragAuthorizeScreenRecording) }) else {
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

    @Test("截图历史合并到最近记录：主菜单保留入口且二级子菜单承载预览卡片")
    @MainActor
    func recentCapturesMergedWithHistory() {
        let menuBar = MenuBarController()
        menuBar.refresh()
        let menu = menuBar.menuForTesting

        let titles = menu.items.map(\.title)
        #expect(titles.contains(L10n.menuRecentHistory))
        #expect(!titles.contains(L10n.historyTitle))

        guard let recentItem = menu.items.first(where: { $0.title == L10n.menuRecentHistory }) else {
            Issue.record("未找到「最近记录」菜单项")
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

    @Test("没有最近记录时，「最近记录」子菜单是一条原生灰字项（不再是一大块白卡片）")
    @MainActor
    func emptyRecentMenuFallsBackToNativeItem() {
        let menuBar = MenuBarController()
        menuBar.historyItemsProvider = { [] }
        menuBar.menuNeedsUpdate(menuBar.recentMenuForTesting)

        let recentMenu = menuBar.recentMenuForTesting
        #expect(recentMenu.items.count == 1)
        let only = recentMenu.items[0]
        #expect(only.title == L10n.menuNoRecentHistory)
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

    // MARK: - 补充：权限状态字符串快照

    @Test("权限状态文案只有 '已授权' 和 '未授权' 两种")
    @MainActor
    func permissionStatusStringsAreConsistent() {
        let menuBar = MenuBarController()
        menuBar.refresh()
        let menu = menuBar.menuForTesting

        // 屏幕录制：文字必须是两种状态文案之一（是哪一种取决于本机授权，不写死）。
        let screenRecordingTitles = [true, false].map { L10n.menuScreenRecordingPermission(granted: $0) }
        let screenRecordingItem = menu.items.first { screenRecordingTitles.contains($0.title) }
        #expect(screenRecordingItem != nil, "菜单中应有屏幕录制权限状态项")

        // 辅助功能
        let accessibilityTitles = [true, false].map { L10n.menuAccessibilityPermission(granted: $0) }
        let axItem = menu.items.first { accessibilityTitles.contains($0.title) }
        #expect(axItem != nil, "菜单中应有辅助功能权限状态项")
    }

    @Test("权限状态项不可点击")
    @MainActor
    func permissionStatusItemsAreDisabled() {
        let menuBar = MenuBarController()
        menuBar.refresh()
        let menu = menuBar.menuForTesting

        let statusTitles = [true, false].flatMap { granted in
            [
                L10n.menuScreenRecordingPermission(granted: granted),
                L10n.menuAccessibilityPermission(granted: granted),
            ]
        }
        let items = menu.items.filter { statusTitles.contains($0.title) }
        #expect(items.count == 2)
        for item in items {
            #expect(!item.isEnabled, "\(item.title) 应为禁用（纯展示状态）")
        }
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
