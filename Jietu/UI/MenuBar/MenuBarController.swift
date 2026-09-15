import AppKit

/// 状态栏常驻入口。用 AppKit `NSStatusItem` 而非 SwiftUI `MenuBarExtra`，
/// 因为后续需要动态子菜单（最近截图）和随状态变化的图标。
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    var onCaptureArea: (() -> Void)?
    var onOpenSystemSettings: (() -> Void)?
    var onOpenOnboarding: (() -> Void)?
    var onQuit: (() -> Void)?

    private let permissionItem = NSMenuItem()

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusButton()
        buildMenu()
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
        button.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "Jietu"
        )
        button.image?.isTemplate = true
        button.toolTip = "Jietu 截图"
    }

    private func buildMenu() {
        let captureItem = NSMenuItem(
            title: "区域截图",
            action: #selector(handleCaptureArea),
            keyEquivalent: ""
        )
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(.separator())

        permissionItem.isEnabled = false
        menu.addItem(permissionItem)

        let settingsItem = NSMenuItem(
            title: "打开「屏幕录制」系统设置…",
            action: #selector(handleOpenSystemSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let onboardingItem = NSMenuItem(
            title: "权限引导…",
            action: #selector(handleOpenOnboarding),
            keyEquivalent: ""
        )
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 Jietu",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func handleCaptureArea() {
        onCaptureArea?()
    }

    @objc private func handleOpenSystemSettings() {
        onOpenSystemSettings?()
    }

    @objc private func handleOpenOnboarding() {
        onOpenOnboarding?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }
}
