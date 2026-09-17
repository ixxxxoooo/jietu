import AppKit
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
}

