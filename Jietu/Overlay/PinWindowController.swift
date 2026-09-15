import AppKit

/// 「钉图」：把截图钉在屏幕上，作为一个可拖动的浮动窗口。
///
/// 双击关闭；支持多张同时钉住。窗口非激活也能拖动（`isMovableByWindowBackground`），
/// 不会抢占前台 App 的焦点。
///
/// @author ixxxxoooo
final class PinWindowController: NSObject {
    private static var controllers: [PinWindowController] = []

    private let window: NSWindow
    private var monitor: Any?

    private init(image: CGImage, screen: NSScreen?) {
        let target = screen ?? NSScreen.main
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 默认按**原始大小**显示：像素尺寸除以屏幕缩放，得到与截图时一致的物理尺寸；
        // 只有超过屏幕 90% 时才等比缩小，避免钉图大到看不全。
        let backingScale = target?.backingScaleFactor ?? 2
        let naturalSize = CGSize(
            width: CGFloat(image.width) / backingScale,
            height: CGFloat(image.height) / backingScale
        )
        let maxSize = CGSize(width: visible.width * 0.9, height: visible.height * 0.9)
        let scale = min(
            1,
            min(maxSize.width / naturalSize.width, maxSize.height / naturalSize.height)
        )
        let size = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)

        // 每多钉一张就向右下错开一点，避免完全重叠。
        let offset = CGFloat(PinWindowController.controllers.count % 6) * 24
        let origin = CGPoint(
            x: visible.maxX - size.width - 24 - offset,
            y: visible.maxY - size.height - 24 - offset
        )

        window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor

        let doubleClick = NSClickGestureRecognizer(
            target: self,
            action: #selector(handleDoubleClick)
        )
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)

        window.contentView = imageView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false

        // Esc 关闭最近钉的一张，方便键盘用户。
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.close()
            return nil
        }
    }

    /// 钉一张截图。多张可共存。
    static func pin(image: CGImage, on screen: NSScreen?) {
        let controller = PinWindowController(image: image, screen: screen)
        controllers.append(controller)
        controller.window.orderFrontRegardless()
    }

    @objc private func handleDoubleClick() {
        close()
    }

    private func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        window.orderOut(nil)
        PinWindowController.controllers.removeAll { $0 === self }
    }
}
