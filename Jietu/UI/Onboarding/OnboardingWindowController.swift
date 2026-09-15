import AppKit
import SwiftUI

final class OnboardingWindowController {
    private var window: NSWindow?
    private let model = OnboardingModel()
    private var previousActivationPolicy: NSApplication.ActivationPolicy = .accessory

    var isVisible: Bool { window?.isVisible ?? false }

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate()
            return
        }

        // 权限引导需要正常出现在 Dock 和 ⌘-Tab 里，否则用户切不回来。
        previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)

        let root = OnboardingView(model: model) { [weak self] in
            self?.close()
        }
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Jietu 权限引导"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        self.window = window

        // 激活可能失败（例如进程由终端派生），此时普通窗口会排在其它 App 之后。
        // orderFrontRegardless 保证引导窗一定可见。
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        // 回到菜单栏代理模式。
        NSApp.setActivationPolicy(previousActivationPolicy)
    }
}
