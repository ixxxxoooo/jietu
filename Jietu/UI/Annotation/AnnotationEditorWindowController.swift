import AppKit
import SwiftUI

/// 标注编辑器窗口。
///
/// 与设置/Onboarding 同样的手动窗口管理：菜单栏代理 App 没有 App 菜单，
/// 打开期间临时切到 `.regular` 以便在 Dock / ⌘-Tab 中可见。
///
/// @author ixxxxoooo
final class AnnotationEditorWindowController: NSObject, NSWindowDelegate {
    private let image: CGImage
    private var window: NSWindow?
    private var previousActivationPolicy: NSApplication.ActivationPolicy = .accessory

    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?
    var onPin: ((CGImage) -> Void)?
    var onClose: (() -> Void)?

    init(image: CGImage) {
        self.image = image
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate()
            return
        }

        previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)

        let root = AnnotationEditorView(
            baseImage: image,
            onCopy: { [weak self] rendered in self?.onCopy?(rendered) },
            onSave: { [weak self] rendered in self?.onSave?(rendered) },
            onPin: { [weak self] rendered in self?.onPin?(rendered) },
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: root)
        let size = AnnotationEditorView.initialWindowSize(for: image, screen: NSScreen.main)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "标注"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(
            width: AnnotationEditorView.minWindowWidth,
            height: AnnotationEditorView.minWindowHeight
        )
        window.contentView = hosting
        window.center()
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        restoreActivationPolicy()
        onClose?()
    }

    private func restoreActivationPolicy() {
        NSApp.setActivationPolicy(previousActivationPolicy)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        restoreActivationPolicy()
        onClose?()
    }
}
