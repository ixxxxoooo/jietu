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
    var onCaptureScrolling: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    var onClearRecents: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onAuthorizeScreenRecording: (() -> Void)?
    var onOpenOnboarding: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onReregisterPermission: (() -> Void)?
    var onRelaunch: (() -> Void)?
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
        menu.addItem(item("滚动长图…", #selector(handleCaptureScrolling), symbol: "scroll"))

        menu.addItem(.separator())

        menu.addItem(recentCaptureItem())
        menu.addItem(item("截图历史…", #selector(handleOpenHistory), symbol: "clock"))
        menu.addItem(item("打开截图文件夹", #selector(handleOpenFolder), symbol: "folder"))

        menu.addItem(.separator())

        permissionItem.isEnabled = false
        menu.addItem(permissionItem)
        menu.addItem(
            item("拖拽授权「屏幕录制」…", #selector(handleAuthorizeScreenRecording), symbol: "hand.draw")
        )
        // 列表里看不到本 App 时的出口：清掉旧记录再重新注册一次。
        menu.addItem(
            item("重新注册「屏幕录制」权限…", #selector(handleReregisterPermission), symbol: nil)
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
        rebuildRecentMenu()
    }
    private func rebuildRecentMenu() {
        recentMenu.removeAllItems()
        let urls = (recentProvider?() ?? []).prefix(Self.recentPreviewCount)

        if urls.isEmpty {
            let empty = NSMenuItem(title: "暂无（截图后会出现在这里）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }

        for url in urls {
            let entry = NSMenuItem(
                title: "",
                action: #selector(handleOpenRecent(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = url
            entry.image = Self.preview(for: url)
            // 图片读不出来时至少还能看文件名点进去。
            if entry.image == nil { entry.title = url.lastPathComponent }
            recentMenu.addItem(entry)
        }

        recentMenu.addItem(.separator())
        let clear = NSMenuItem(title: "清除记录", action: #selector(handleClearRecents), keyEquivalent: "")
        clear.target = self
        recentMenu.addItem(clear)
    }

    // MARK: - Thumbnails

    /// 最近截图只预览这么多张。
    private static let recentPreviewCount = 10
    private static let previewHeight: CGFloat = 56
    private static let previewMinWidth: CGFloat = 80
    private static let previewMaxWidth: CGFloat = 132

    /// 预览图：等比裁切到统一高度，左下角烙上截图时间。
    ///
    /// 时间直接画进图里而不是走菜单项标题：条目只放一张图，看起来更像「预览」。
    ///
    /// 用 `drawingHandler` 而不是自己拼位图代表：手工建 rep 时 `NSImage.size`
    /// 会在绘制阶段被折半（视网膜下量出来只有一半大），交给 AppKit 渲染则尺寸稳定。
    private static func preview(for url: URL) -> NSImage? {
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0
        else { return nil }

        let aspect = source.size.width / source.size.height
        let size = NSSize(
            width: min(max((previewHeight * aspect).rounded(), previewMinWidth), previewMaxWidth),
            height: previewHeight
        )
        let time = timeText(for: url)
        return NSImage(size: size, flipped: false) { rect in
            draw(source: source, in: rect, time: time)
            return true
        }
    }

    private static func draw(source: NSImage, in rect: NSRect, time: String) {
        // 铺满画布（等比裁切），保证底部时间条区域始终有图垫底。
        let fillScale = max(rect.width / source.size.width, rect.height / source.size.height)
        let filled = NSSize(
            width: source.size.width * fillScale,
            height: source.size.height * fillScale
        )
        source.draw(
            in: NSRect(
                x: rect.midX - filled.width / 2,
                y: rect.midY - filled.height / 2,
                width: filled.width,
                height: filled.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (time as NSString).size(withAttributes: attributes)
        let inset: CGFloat = 4
        let padding = NSSize(width: 4, height: 2)
        let badge = NSRect(
            x: rect.minX + inset,
            y: rect.minY + inset,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        (time as NSString).draw(
            at: NSPoint(x: badge.minX + padding.width, y: badge.minY + padding.height),
            withAttributes: attributes
        )
    }

    /// 今天只报时分秒，更早的补上日期。
    private static func timeText(for url: URL) -> String {
        let date = FilenameTemplate.captureDate(of: url)
        let isToday = Calendar.current.isDateInToday(date)
        return (isToday ? timeOnlyFormatter : dateTimeFormatter).string(from: date)
    }

    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

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

    @objc private func handleOpenOnboarding() {
        onOpenOnboarding?()
    }

    @objc private func handleOpenSettings() {
        onOpenSettings?()
    }

    @objc private func handleReregisterPermission() {
        onReregisterPermission?()
    }

    @objc private func handleRelaunch() {
        onRelaunch?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }
}
