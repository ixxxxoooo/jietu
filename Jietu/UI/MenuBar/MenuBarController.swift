import AppKit

/// 状态栏常驻入口。用 AppKit `NSStatusItem` 而非 SwiftUI `MenuBarExtra`，
/// 因为需要动态子菜单（最近截图）和随状态变化的图标。
///
/// @author ixxxxoooo
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let permissionItem = NSMenuItem()
    private let recentMenu = NSMenu()
    /// 确认闪烁用的任务，重复截图时先取消上一次。
    private var flashTask: Task<Void, Never>?

    var onCaptureArea: (() -> Void)?
    var onCaptureWindow: (() -> Void)?
    var onCaptureFullScreen: (() -> Void)?
    var onCaptureTimed: ((TimeInterval) -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    var onClearRecents: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenSystemSettings: (() -> Void)?
    var onOpenOnboarding: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    /// 最近截图提供者，菜单每次弹出时拉取一次。
    var recentProvider: (() -> [URL])?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusButton()
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func refresh() {
        let granted = ScreenCapturePermission.isGranted
        permissionItem.title = granted ? "屏幕录制权限：已授权" : "屏幕录制权限：未授权"
        permissionItem.image = NSImage(
            systemSymbolName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
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

        menu.addItem(.separator())

        menu.addItem(recentCaptureItem())
        menu.addItem(item("截图历史…", #selector(handleOpenHistory), symbol: "clock"))
        menu.addItem(item("打开截图文件夹", #selector(handleOpenFolder), symbol: "folder"))

        menu.addItem(.separator())

        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        menu.addItem(
            item("打开「屏幕录制」系统设置…", #selector(handleOpenSystemSettings), symbol: nil)
        )
        menu.addItem(item("权限引导…", #selector(handleOpenOnboarding), symbol: nil))

        menu.addItem(.separator())

        let preferences = item("偏好设置…", #selector(handleOpenSettings), symbol: "gearshape")
        preferences.keyEquivalent = ","
        menu.addItem(preferences)

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
        rebuildRecentMenu()
    }
    private func rebuildRecentMenu() {
        recentMenu.removeAllItems()
        let urls = recentProvider?() ?? []

        if urls.isEmpty {
            let empty = NSMenuItem(title: "暂无", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }

        for url in urls {
            let entry = NSMenuItem(
                title: url.lastPathComponent,
                action: #selector(handleOpenRecent(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = url
            entry.image = Self.thumbnail(for: url, height: 18)
            recentMenu.addItem(entry)
        }

        recentMenu.addItem(.separator())
        let clear = NSMenuItem(title: "清除记录", action: #selector(handleClearRecents), keyEquivalent: "")
        clear.target = self
        recentMenu.addItem(clear)
    }

    /// 菜单项缩略图（等比缩放到指定高度）。
    private static func thumbnail(for url: URL, height: CGFloat) -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.size.height > 0 else { return nil }
        let aspect = image.size.width / image.size.height
        let size = NSSize(width: max(1, min(height * aspect, 64)), height: height)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
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

    @objc private func handleOpenSystemSettings() {
        onOpenSystemSettings?()
    }

    @objc private func handleOpenOnboarding() {
        onOpenOnboarding?()
    }

    @objc private func handleOpenSettings() {
        onOpenSettings?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }
}
