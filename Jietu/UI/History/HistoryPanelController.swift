import AppKit
import SwiftUI

/// 托盘历史面板（截图历史）。
///
/// @author ixxxxoooo
final class HistoryPanelController: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 320, height: 560)

    private var window: NSPanel?
    private var monitor: Any?

    /// 返回最近截图（路径集合）。
    var itemsProvider: (() -> [HistoryItem])?
    var onSelect: ((URL) -> Void)?

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible {
            close()
        } else {
            present()
        }
    }

    func present() {
        close()

        let root = HistoryView(
            items: itemsProvider?() ?? [],
            onSelect: { [weak self] url in
                self?.onSelect?(url)
            },
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.delegate = self

        // 贴右上角（菜单栏下方）。
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(
                NSRect(
                    x: visible.maxX - Self.size.width - 8,
                    y: visible.maxY - Self.size.height - 8,
                    width: Self.size.width,
                    height: Self.size.height
                ),
                display: false
            )
        } else {
            panel.center()
        }
        self.window = panel

        panel.orderFrontRegardless()
        panel.makeKey()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.close()
            return nil
        }
    }

    func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        window?.orderOut(nil)
        window = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
