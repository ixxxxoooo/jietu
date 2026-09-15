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
    /// 就地编辑时选区在屏幕上的矩形，用来把窗口放到选区附近。
    private let anchor: CGRect?
    private var window: NSWindow?
    private var previousActivationPolicy: NSApplication.ActivationPolicy = .accessory

    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?
    var onClose: (() -> Void)?

    init(image: CGImage, anchor: CGRect? = nil) {
        self.image = image
        self.anchor = anchor
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

        let inline = (anchor?.width ?? 0) > 1 && (anchor?.height ?? 0) > 1

        previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)

        let root = AnnotationEditorView(
            baseImage: image,
            inline: inline,
            onCopy: { [weak self] rendered in self?.onCopy?(rendered) },
            onSave: { [weak self] rendered in self?.onSave?(rendered) },
            onPin: { [weak self] rendered, frame in
                self?.pinInPlace(rendered, globalFrame: frame)
            },
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: root)

        let size = inline
            ? inlineWindowSize(for: image)
            : AnnotationEditorView.initialWindowSize(for: image, screen: NSScreen.main)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window: NSWindow
        if inline {
            // 无边框：图片在上、工具栏贴在下，直接贴着选区，看起来像「就地编辑」。
            let keyable = KeyableBorderlessWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            keyable.isOpaque = false
            keyable.backgroundColor = .clear
            keyable.hasShadow = true
            keyable.level = .floating
            window = keyable
        } else {
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "标注"
            window.contentMinSize = NSSize(
                width: AnnotationEditorView.minWindowWidth,
                height: AnnotationEditorView.minWindowHeight
            )
        }
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        if inline {
            positionInline(window, size: size)
        } else {
            positionWindow(window, size: size)
        }
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    /// 就地编辑窗口尺寸：图片原始大小 + 底部工具栏。
    private func inlineWindowSize(for image: CGImage) -> CGSize {
        let scale = max(1, anchorScreen()?.backingScaleFactor ?? 2)
        let imageSize = CGSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        let width = max(imageSize.width, 620)
        return CGSize(width: width, height: imageSize.height + AnnotationEditorView.toolbarHeight)
    }

    /// 就地编辑：让图片区域正好覆盖选区，工具栏落在选区下方。
    private func positionInline(_ window: NSWindow, size: CGSize) {
        guard let anchor else {
            window.center()
            return
        }
        let screen = anchorScreen() ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let imageHeight = size.height - AnnotationEditorView.toolbarHeight
        var origin = CGPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.maxY - size.height
        )
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(
            max(origin.y, visible.minY),
            visible.maxY - size.height
        )
        _ = imageHeight
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func anchorScreen() -> NSScreen? {
        guard let anchor else { return NSScreen.main }
        return NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        restoreActivationPolicy()
        onClose?()
    }

    /// 「原地钉图」：按编辑器里图片当前所在的位置与大小钉住，然后关闭编辑器。
    private func pinInPlace(_ image: CGImage, globalFrame: CGRect) {
        let target = screenRect(fromGlobal: globalFrame)
        PinWindowController.pin(
            image: image,
            on: window?.screen ?? NSScreen.main,
            targetFrame: target
        )
        close()
    }

    /// SwiftUI 全局坐标（窗口内，原点左上）→ 屏幕坐标（AppKit，原点左下）。
    private func screenRect(fromGlobal rect: CGRect) -> CGRect? {
        guard let window, let content = window.contentView,
            rect.width > 1, rect.height > 1
        else { return nil }
        let appKitRect = NSRect(
            x: rect.minX,
            y: content.bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        return window.convertToScreen(appKitRect)
    }

    private func restoreActivationPolicy() {
        NSApp.setActivationPolicy(previousActivationPolicy)
    }

    /// 就地编辑：把窗口放到选区附近；否则居中。
    private func positionWindow(_ window: NSWindow, size: CGSize) {
        guard let anchor, anchor.width > 1, anchor.height > 1 else {
            window.center()
            return
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = CGPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.midY - size.height / 2
        )
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        restoreActivationPolicy()
        onClose?()
    }
}

/// 无边框但可成为 key window（否则收不到键盘事件）。
///
/// @author ixxxxoooo
final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
