import AppKit

/// 状态栏常驻入口。用 AppKit `NSStatusItem` 而非 SwiftUI `MenuBarExtra`，
/// 因为需要动态子菜单（最近截图）和随状态变化的图标。
///
/// @author ixxxxoooo
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let permissionItem = NSMenuItem()
    private let accessibilityPermissionItem = NSMenuItem()
    private let recentMenu = NSMenu()

    var onCaptureArea: (() -> Void)?
    var onCaptureWindow: (() -> Void)?
    var onCaptureFullScreen: (() -> Void)?
    var onCaptureTimed: ((TimeInterval) -> Void)?
    var onCaptureScrolling: (() -> Void)?
    var onRecordRegion: (() -> Void)?
    var onRecordWindow: (() -> Void)?
    var onRecordFullScreen: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    var onClearRecents: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onSelectHistoryItem: ((HistoryItem) -> Void)?
    var onAuthorizeScreenRecording: (() -> Void)?
    var onAuthorizeAccessibility: (() -> Void)?
    var onOpenOnboarding: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRelaunch: (() -> Void)?
    var onQuit: (() -> Void)?

    /// 最近截图提供者，菜单每次弹出时拉取一次。
    var recentProvider: (() -> [URL])?
    /// 历史条目提供者（优先于 recentProvider）。
    var historyItemsProvider: (() -> [HistoryItem])?

    /// 供单元测试检查菜单项。
    var menuForTesting: NSMenu { menu }
    var recentMenuForTesting: NSMenu { recentMenu }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusButton()
        buildMenu()
        menu.delegate = self
        recentMenu.delegate = self
        statusItem.menu = menu
    }

    func refresh() {
        let granted = ScreenCapturePermission.isGranted
        permissionItem.title = granted ? "屏幕录制权限：已授权" : "屏幕录制权限：未授权"
        permissionItem.image = NSImage(
            systemSymbolName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )

        let axGranted = AccessibilityPermission.isGranted
        accessibilityPermissionItem.title = axGranted ? "辅助功能权限：已授权" : "辅助功能权限：未授权"
        accessibilityPermissionItem.image = NSImage(
            systemSymbolName: axGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.icon("camera.viewfinder", description: "Jietu")
        button.toolTip = "Jietu 截图"
    }

    /// 图标按 16pt 取：SF Symbol 默认的文本字号渲染出来只有 12.5pt 墨迹，
    /// 比菜单栏里相邻的图标（14~17pt）小一档，显式放大后才齐平。
    private static func icon(_ symbol: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
        image?.isTemplate = true
        return image
    }

    private func buildMenu() {
        // 截图与录制各占一个子菜单：两家族的动作不再在同一列里混着排。
        menu.addItem(captureItem())
        menu.addItem(recordingItem())

        menu.addItem(.separator())

        menu.addItem(recentCaptureItem())
        menu.addItem(item("打开截图文件夹", #selector(handleOpenFolder), symbol: "folder"))

        menu.addItem(.separator())

        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        menu.addItem(
            item("拖拽授权「屏幕录制」…", #selector(handleAuthorizeScreenRecording), symbol: "hand.draw")
        )
        accessibilityPermissionItem.isEnabled = false
        menu.addItem(accessibilityPermissionItem)
        menu.addItem(
            item("拖拽授权「辅助功能」…", #selector(handleAuthorizeAccessibility), symbol: "hand.draw")
        )
        menu.addItem(item("权限引导…", #selector(handleOpenOnboarding), symbol: nil))

        menu.addItem(.separator())

        let preferences = item("偏好设置…", #selector(handleOpenSettings), symbol: "gearshape")
        preferences.keyEquivalent = ","
        menu.addItem(preferences)

        menu.addItem(.separator())

        // 屏幕录制的授权在授权时的那个进程里不生效，卡住时重启是最快的路。
        menu.addItem(item("重启 Jietu", #selector(handleRelaunch), symbol: "arrow.clockwise"))

        menu.addItem(.separator())

        let quit = item("退出 Jietu", #selector(handleQuit), symbol: nil)
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(
        _ title: String,
        _ action: Selector,
        symbol: String?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    /// 「截图 ▸」：区域 / 窗口 / 全屏 / 定时 / 滚动长图。
    private func captureItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "截图", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.addItem(item("区域截图", #selector(handleCaptureArea), symbol: "viewfinder"))
        submenu.addItem(item("窗口截图", #selector(handleCaptureWindow), symbol: "macwindow"))
        submenu.addItem(item("全屏截图", #selector(handleCaptureFullScreen), symbol: "rectangle.fill"))
        submenu.addItem(timedCaptureItem())
        submenu.addItem(item("滚动长图…", #selector(handleCaptureScrolling), symbol: "scroll"))
        parent.submenu = submenu
        return parent
    }

    /// 「录制 ▸」：区域 / 窗口 / 全屏。
    private func recordingItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "录制", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.addItem(item("区域录制", #selector(handleRecordRegion), symbol: "record.circle"))
        submenu.addItem(item("窗口录制", #selector(handleRecordWindow), symbol: "macwindow"))
        submenu.addItem(item("全屏录制", #selector(handleRecordFullScreen), symbol: "rectangle.fill"))
        parent.submenu = submenu
        return parent
    }

    private func timedCaptureItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "定时截图", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let submenu = NSMenu()
        for seconds in [3.0, 5.0, 10.0] {
            let entry = NSMenuItem(
                title: "\(Int(seconds)) 秒后",
                action: #selector(handleCaptureTimed(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = seconds
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    private func recentCaptureItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "最近截图", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        parent.submenu = recentMenu
        return parent
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == self.menu {
            refresh()
            rebuildRecentMenu()
        } else if menu == recentMenu {
            rebuildRecentMenu()
        }
    }

    private func rebuildRecentMenu() {
        recentMenu.removeAllItems()

        let items: [HistoryItem]
        if let provider = historyItemsProvider {
            items = provider()
        } else if let urlProvider = recentProvider {
            items = urlProvider().prefix(20).map { url in
                HistoryItem(
                    id: url.path,
                    date: FilenameTemplate.captureDate(of: url),
                    image: HistoryThumbnailCache.shared.image(for: url),
                    url: url,
                    cgImage: nil
                )
            }
        } else {
            items = []
        }

        let contentView = RecentHistoryMenuView(
            items: items,
            onSelect: { [weak self] item in
                self?.menu.cancelTracking()
                self?.onSelectHistoryItem?(item)
            },
            onRevealInFinder: { [weak self] item in
                self?.menu.cancelTracking()
                if let url = item.url {
                    self?.onOpenRecent?(url)
                }
            },
            onCopy: { item in
                if let cg = item.cgImage {
                    CaptureOutput.copyToPasteboard(cg)
                } else if let img = item.image,
                          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    CaptureOutput.copyToPasteboard(cg)
                }
            },
            onClear: { [weak self] in
                self?.onClearRecents?()
                self?.rebuildRecentMenu()
            },
            onOpenFolder: { [weak self] in
                self?.menu.cancelTracking()
                self?.onOpenFolder?()
            }
        )

        let hostingView = MenuHostingView(rootView: contentView)
        let height = Self.calculateRecentMenuHeight(for: items)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: height)

        let hostItem = NSMenuItem()
        hostItem.view = hostingView
        recentMenu.addItem(hostItem)
    }

    /// 根据截图数量与尺寸动态计算最近截图子菜单的合适高度，保证至少容纳 4~5 张图，且不超过屏幕可用高度。
    static func calculateRecentMenuHeight(for items: [HistoryItem]) -> CGFloat {
        if items.isEmpty {
            return 130
        }

        // 标头 (37) + 分隔线 (1) + 上下边距 (16) = 54
        let chromeHeight: CGFloat = 54
        let itemSpacing: CGFloat = 8

        var totalCardsHeight: CGFloat = 0
        for item in items {
            let thumbHeight: CGFloat
            if let image = item.image, image.size.width > 0, image.size.height > 0 {
                let aspect = image.size.width / image.size.height
                let rawHeight = 286 / aspect
                thumbHeight = min(max(rawHeight, 60), 110)
            } else if let cg = item.cgImage, cg.width > 0, cg.height > 0 {
                let aspect = CGFloat(cg.width) / CGFloat(cg.height)
                let rawHeight = 286 / aspect
                thumbHeight = min(max(rawHeight, 60), 110)
            } else {
                thumbHeight = 80
            }
            // 卡片上下边距(14) + 标头行(16) + 间隙(5) + 缩略图 + 间隙(5) + 操作栏(22)
            let cardHeight = 14 + 16 + 5 + thumbHeight + 5 + 22
            totalCardsHeight += cardHeight
        }

        let totalSpacing = CGFloat(max(0, items.count - 1)) * itemSpacing
        let naturalContentHeight = chromeHeight + totalCardsHeight + totalSpacing

        // 获取当前屏幕可用高度，并预留上下安全边距（顶端菜单栏约 30pt、底栏/Dock 约 50pt）
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let maxAllowedHeight = max(420, screenHeight - 90)

        // 动态自适应：记录少时精准贴合内容高度，记录多时上限为屏幕最大安全高度并允许滚动
        return min(naturalContentHeight, maxAllowedHeight)
    }

    // MARK: - Actions

    @objc private func handleCaptureArea() {
        onCaptureArea?()
    }

    @objc private func handleCaptureWindow() {
        onCaptureWindow?()
    }

    @objc private func handleCaptureFullScreen() {
        onCaptureFullScreen?()
    }

    @objc private func handleCaptureTimed(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        onCaptureTimed?(seconds)
    }

    @objc private func handleRecordRegion() {
        onRecordRegion?()
    }

    @objc private func handleRecordWindow() {
        onRecordWindow?()
    }

    @objc private func handleRecordFullScreen() {
        onRecordFullScreen?()
    }

    @objc private func handleCaptureScrolling() {
        onCaptureScrolling?()
    }

    @objc private func handleOpenRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenRecent?(url)
    }

    @objc private func handleClearRecents() {
        onClearRecents?()
    }

    @objc private func handleOpenFolder() {
        onOpenFolder?()
    }

    @objc private func handleOpenHistory() {
        onOpenHistory?()
    }

    @objc private func handleAuthorizeScreenRecording() {
        onAuthorizeScreenRecording?()
    }

    @objc private func handleAuthorizeAccessibility() {
        onAuthorizeAccessibility?()
    }

    @objc private func handleOpenOnboarding() {
        onOpenOnboarding?()
    }

    @objc private func handleOpenSettings() {
        onOpenSettings?()
    }

    @objc private func handleRelaunch() {
        onRelaunch?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }
}
