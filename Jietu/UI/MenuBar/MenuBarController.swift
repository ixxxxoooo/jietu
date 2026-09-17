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
    /// 确认闪烁用的任务，重复截图时先取消上一次。
    private var flashTask: Task<Void, Never>?

    var onCaptureArea: (() -> Void)?
    var onCaptureWindow: (() -> Void)?
    var onCaptureFullScreen: (() -> Void)?
    var onCaptureTimed: ((TimeInterval) -> Void)?
    var onCaptureScrolling: (() -> Void)?
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
        button.image?.isTemplate = true
        button.toolTip = "Jietu 截图"
    }

    /// 截图成功后闪一下图标：保存是静默的，这是最轻量的确认反馈。
    func flashCaptureFeedback() {
        guard let button = statusItem.button else { return }
        flashTask?.cancel()
        button.image = Self.icon("checkmark.circle.fill", description: "已截图")

        flashTask = Task { @MainActor [weak self] in
            // 亮灭共 5 次，约 0.9 秒。
            for tick in 1...5 {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self else { return }
                if tick == 5 {
                    self.configureStatusButton()
                } else {
                    let symbol = tick % 2 == 0 ? "checkmark.circle.fill" : "camera.viewfinder"
                    self.statusItem.button?.image = Self.icon(symbol, description: "Jietu")
                }
            }
        }
    }

    private static func icon(_ symbol: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    private func buildMenu() {
        menu.addItem(item("区域截图", #selector(handleCaptureArea), symbol: "viewfinder"))
        menu.addItem(item("窗口截图", #selector(handleCaptureWindow), symbol: "macwindow"))
        menu.addItem(item("全屏截图", #selector(handleCaptureFullScreen), symbol: "rectangle.fill"))
        menu.addItem(timedCaptureItem())
        menu.addItem(item("滚动长图…", #selector(handleCaptureScrolling), symbol: "scroll"))

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
        let height: CGFloat
        if items.isEmpty {
            height = 130
        } else {
            let count = min(items.count, 5)
            height = min(CGFloat(count) * 165 + 44, 480)
        }
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: height)

        let hostItem = NSMenuItem()
        hostItem.view = hostingView
        recentMenu.addItem(hostItem)
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
