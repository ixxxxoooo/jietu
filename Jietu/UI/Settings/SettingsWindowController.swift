import AppKit
import SwiftUI

/// 偏好设置窗口。
///
/// 与 Onboarding 同样的做法：菜单栏代理 App（LSUIElement）没有 App 菜单，
/// SwiftUI 的 `Settings` 场景够不着，所以用普通窗口手动管理，
/// 打开期间临时切到 `.regular` 以便出现在 Dock / ⌘-Tab 里。
///
/// @author ixxxxoooo
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static let contentSize = Theme.Size.settingsWindow

    private let settings: SettingsStore
    private var window: NSWindow?
    private var previousActivationPolicy: NSApplication.ActivationPolicy = .accessory

    /// 热键改变回调，由 AppDelegate 负责注销旧热键、注册新热键（nil 表示清除）。
    var onHotkeyChange: ((HotkeyAction, Hotkey?) -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// 展示设置窗口；已存在则前置。
    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate()
            return
        }

        previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)

        let root = SettingsView(settings: settings) { [weak self] action, hotkey in
            self?.onHotkeyChange?(action, hotkey)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.contentSize)
        hosting.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Jietu 偏好设置"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.delegate = self
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        restoreActivationPolicy()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        restoreActivationPolicy()
    }

    /// 关闭后回到菜单栏代理模式。
    private func restoreActivationPolicy() {
        NSApp.setActivationPolicy(previousActivationPolicy)
    }
}
