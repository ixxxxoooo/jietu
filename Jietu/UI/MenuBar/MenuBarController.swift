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
    /// 某个动作当前配的热键（没配返回 nil）：菜单项据此显示 / 不显示快捷键。
    var hotkeyProvider: ((HotkeyAction) -> Hotkey?)?

    var onRecordRegion: (() -> Void)?
    var onRecordWindow: (() -> Void)?
    var onRecordFullScreen: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    var onClearRecents: (() -> Void)?
    var onOpenFolder: (() -> Void)?

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
        refreshHotkeyTitles()
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

    /// 带热键的菜单项（动作 + item）：菜单弹出时按当前设置重刷快捷键显示。
    private var hotkeyItems: [(HotkeyAction, NSMenuItem)] = []

    private func buildMenu() {
        // 截图四条 + 滚动长图留在顶层（都是最常用的），录制三条另起一组，
        // 中间用一条分隔线隔开——不收起子菜单，一步就能点到。
        menu.addItem(hotkeyItem(.areaCapture, "区域截图", #selector(handleCaptureArea), "viewfinder"))
        menu.addItem(
            hotkeyItem(.windowCapture, "窗口截图", #selector(handleCaptureWindow), "macwindow")
        )
        menu.addItem(
            hotkeyItem(
                .fullScreenCapture, "全屏截图", #selector(handleCaptureFullScreen), "rectangle.fill"
            )
        )
        menu.addItem(timedCaptureItem())  // 自带子菜单，下一行补上快捷键显示
        menu.addItem(
            hotkeyItem(.scrollingCapture, "滚动长图…", #selector(handleCaptureScrolling), "scroll")
        )

        menu.addItem(.separator())

        menu.addItem(
            hotkeyItem(.screenRecording, "区域录制", #selector(handleRecordRegion), "record.circle")
        )
        menu.addItem(
            hotkeyItem(.windowRecording, "窗口录制", #selector(handleRecordWindow), "macwindow")
        )
        menu.addItem(
            hotkeyItem(
                .fullScreenRecording, "全屏录制", #selector(handleRecordFullScreen), "rectangle.fill"
            )
        )

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

    /// 绑了全局热键的菜单项：**配了就在菜单里显示那个快捷键，没配就什么都不显示**。
    ///
    /// 这里的 `keyEquivalent` 只当显示用：菜单挂在状态栏按钮上、不在 App 的主菜单里，
    /// AppKit 那套「主菜单快捷键匹配」够不着它，所以不会和 Carbon 全局热键重复触发
    /// （菜单打开时按同一组合键会高亮 / 触发这一条，那是系统自己的行为）。
    private func hotkeyItem(
        _ action: HotkeyAction,
        _ title: String,
        _ selector: Selector,
        _ symbol: String
    ) -> NSMenuItem {
        let item = item(title, selector, symbol: symbol)
        hotkeyItems.append((action, item))
        apply(hotkey: hotkeyProvider?(action), to: item)
        return item
    }

    private func apply(hotkey: Hotkey?, to item: NSMenuItem) {
        guard let hotkey, let key = hotkey.menuKey, !key.isEmpty else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = hotkey.cocoaModifiers
    }

    /// 菜单每次弹出都重刷一遍：用户在设置页改了快捷键，下一次打开菜单就是新的。
    private func refreshHotkeyTitles() {
        for (action, item) in hotkeyItems {
            apply(hotkey: hotkeyProvider?(action), to: item)
        }
    }

    private func timedCaptureItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "定时截图", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        // 配了「定时截图」热键也显示出来（它触发的是默认那档 3 秒）。
        hotkeyItems.append((.timedCapture, parent))
        apply(hotkey: hotkeyProvider?(.timedCapture), to: parent)
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

        // 空历史：不要那张 320pt 宽的预览卡片——它在菜单里是一大块白底 + 自带标题栏 +
        // 窗口式阴影，跟菜单本身完全不是一回事（用户报的「显示异常」就是它）。
        // 一条原生的灰字菜单项就够了：和「暂无…」这种系统写法一致。
        guard !items.isEmpty else {
            let empty = NSMenuItem(title: "暂无最近截图", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
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
                // 会话内那份直接拷位图；重启后回来的条目只有文件——**从文件读原图**，
                // 绝不能拿列表里的缩略图当原图拷（拷出来会是糊的）。
                if let cg = item.cgImage {
                    CaptureOutput.copyToPasteboard(cg)
                } else if let url = item.url, let img = NSImage(contentsOf: url),
                    let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
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
