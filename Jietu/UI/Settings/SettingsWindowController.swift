import AppKit
import SwiftUI

/// 偏好设置窗口。
///
/// 与参考项目一致：菜单栏代理 App（LSUIElement）没有 App 菜单，SwiftUI 的 `Settings`
/// 场景够不着，所以用普通窗口手管；打开期间临时切到 `.regular` 以便出现在 Dock 里。
///
/// 设置窗是**唯一保留系统标题栏玻璃带**的窗口（内容仍用 `.fullSizeContentView` 通到栏下），
/// 分区标题与回退 / 前进交给 `SettingsToolbarController`，侧栏 / 详情交给
/// `NSSplitViewController`——只有它俩能拿到系统 sidebar 材质与 `.sidebarTrackingSeparator`。
///
/// @author ixxxxoooo
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static let contentSize = Theme.Size.settingsWindow
    private static let autosaveName = "JietuSettingsWindow"

    private let settings: SettingsStore
    private var window: NSWindow?
    /// 与窗口同生命周期重建，chrome 的状态不会比它装饰的窗口活得久。
    private var chrome: SettingsToolbarController?
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

        let navigation = SettingsNavigationState()
        let split = SettingsSplitViewController(
            sidebar: SettingsSidebarView(navigation: navigation),
            detail: SettingsDetailView(
                settings: settings,
                navigation: navigation
            ) { [weak self] action, hotkey in
                self?.onHotkeyChange?(action, hotkey)
            }
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            // `.miniaturizable` / `.resizable` 缺一不可，否则黄绿两个灯是灰的。
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = navigation.section.title
        // 先按参考项目建窗，再由 chrome 把标题栏恢复成系统玻璃带。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // 不让 AppKit 在启动时凭空恢复窗口（那时什么都还没接好）。
        window.isRestorable = false
        window.contentMinSize = Self.contentSize
        window.contentViewController = split
        // `contentViewController` 会把 frame 重置成控制器的 fitting size。
        window.setContentSize(Self.contentSize)
        window.delegate = self

        let chrome = SettingsToolbarController(navigation: navigation)
        self.chrome = chrome
        chrome.install(in: window)
        self.window = window

        window.setFrameAutosaveName(Self.autosaveName)
        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        chrome = nil
        restoreActivationPolicy()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        chrome = nil
        restoreActivationPolicy()
    }

    /// 关闭后回到菜单栏代理模式。
    private func restoreActivationPolicy() {
        NSApp.setActivationPolicy(previousActivationPolicy)
    }
}
