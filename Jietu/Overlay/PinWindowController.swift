import AppKit

/// 「钉图」：把截图钉在屏幕上，作为一个可拖动、可缩放的浮动窗口。
///
/// 支持：
/// - 拖动任意位置移动
/// - 拖动边缘 / 角改变大小（保持宽高比）
/// - 滚轮 / 触控板捏合缩放
/// - 右键菜单：OCR 识别文字、复制图像、关闭
/// - 双击关闭；Esc 关闭
///
/// @author ixxxxoooo
final class PinWindowController: NSObject {
    private static var controllers: [PinWindowController] = []

    private let window: NSWindow
    private let content: PinContentView
    private var monitor: Any?

    /// 钉一张截图。多张可共存。
    ///
    /// - Parameter targetFrame: 指定屏幕坐标位置与大小（用于「原地钉图」）；
    ///   为 nil 时按原始大小钉在屏幕右上角。
    static func pin(image: CGImage, on screen: NSScreen?, targetFrame: CGRect? = nil) {
        let controller = PinWindowController(image: image, screen: screen, targetFrame: targetFrame)
        controllers.append(controller)
        controller.window.orderFrontRegardless()
    }

    private init(image: CGImage, screen: NSScreen?, targetFrame: CGRect?) {
        let target = screen ?? NSScreen.main
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let frame: NSRect
        if let targetFrame, targetFrame.width > 1, targetFrame.height > 1 {
            // 原地钉图：直接使用编辑器里图片所在的位置与大小。
            frame = targetFrame
        } else {
            // 默认按**原始大小**显示：像素尺寸除以屏幕缩放。超过屏幕 90% 才等比缩小。
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
            frame = NSRect(origin: origin, size: size)
        }

        content = PinContentView(frame: NSRect(origin: .zero, size: frame.size), image: image)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.contentView = content
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true

        content.onRequestClose = { [weak self] in self?.close() }
        content.onOCR = { [weak self] in self?.recognizeText() }

        // Esc 关闭最近钉的一张，方便键盘用户。
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.close()
            return nil
        }
    }

    private func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        window.orderOut(nil)
        PinWindowController.controllers.removeAll { $0 === self }
    }

    /// OCR：识别钉图里的文字并复制到剪贴板，弹窗展示结果。
    private func recognizeText() {
        let image = content.cgImage
        Task { @MainActor in
            let text = await OCRService.recognizeText(in: image)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !text.isEmpty {
                pasteboard.setString(text, forType: .string)
            }

            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = text.isEmpty ? "没有识别到文字" : "已识别文字（已复制到剪贴板）"
            alert.informativeText = text.isEmpty ? "" : String(text.prefix(800))
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}

/// 钉图的绘制与交互载体。
///
/// 用自绘而非 `NSImageView`：需要自己处理移动、边缘缩放与缩放，避免和系统
/// 的窗口拖拽 / 缩放行为冲突。
///
/// @author ixxxxoooo
final class PinContentView: NSView {
    private enum Edge {
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
    }

    let cgImage: CGImage
    private let nsImage: NSImage
    private var activeEdge: Edge?
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    private var trackingArea: NSTrackingArea?

    var onRequestClose: (() -> Void)?
    var onOCR: (() -> Void)?

    private let edgeTolerance: CGFloat = 7

    init(frame: NSRect, image: CGImage) {
        self.cgImage = image
        self.nsImage = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        nsImage.draw(in: bounds)
    }

    // MARK: - Tracking / cursors

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        switch edge(at: convert(event.locationInWindow, from: nil)) {
        case .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight, .top, .bottom:
            NSCursor.crosshair.set()
        case nil:
            NSCursor.openHand.set()
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onRequestClose?()
            return
        }
        activeEdge = edge(at: convert(event.locationInWindow, from: nil))
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        if let activeEdge {
            resize(window: window, edge: activeEdge, current: current)
        } else {
            window.setFrameOrigin(
                NSPoint(
                    x: startFrame.origin.x + (current.x - startMouse.x),
                    y: startFrame.origin.y + (current.y - startMouse.y)
                )
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        activeEdge = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let ocr = NSMenuItem(title: "识别文字（OCR）", action: #selector(handleOCR), keyEquivalent: "")
        ocr.target = self
        menu.addItem(ocr)
        let copy = NSMenuItem(title: "复制图像", action: #selector(handleCopy), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭", action: #selector(handleClose), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Zoom

    override func scrollWheel(with event: NSEvent) {
        let raw = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / 8
            : event.scrollingDeltaY
        let factor = min(1.5, max(0.67, 1 + raw * 0.05))
        zoom(by: factor, at: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    /// 以光标为锚点缩放（保持宽高比）。
    private func zoom(by factor: CGFloat, at point: CGPoint) {
        guard let window, factor > 0, factor != 1 else { return }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return }
        let newWidth = max(80, frame.width * factor)
        let newHeight = max(56, frame.height * factor)
        let relX = point.x / frame.width
        let relY = point.y / frame.height
        let originX = frame.origin.x + (frame.width - newWidth) * relX
        let originY = frame.origin.y + (frame.height - newHeight) * relY
        window.setFrame(
            NSRect(x: originX, y: originY, width: newWidth, height: newHeight),
            display: true
        )
    }

    // MARK: - Resize

    private func edge(at point: CGPoint) -> Edge? {
        let nearLeft = point.x <= edgeTolerance
        let nearRight = point.x >= bounds.width - edgeTolerance
        let nearBottom = point.y <= edgeTolerance
        let nearTop = point.y >= bounds.height - edgeTolerance

        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft { return .left }
        if nearRight { return .right }
        if nearBottom { return .bottom }
        if nearTop { return .top }
        return nil
    }

    /// 拖拽边缘 / 角改变大小，保持宽高比，未拖动的一侧固定。
    private func resize(window: NSWindow, edge: Edge, current: NSPoint) {
        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y
        let aspect = startFrame.height > 0 ? startFrame.width / startFrame.height : 1

        let affectsLeft = edge == .left || edge == .topLeft || edge == .bottomLeft
        let affectsRight = edge == .right || edge == .topRight || edge == .bottomRight
        let affectsBottom = edge == .bottom || edge == .bottomLeft || edge == .bottomRight
        let affectsTop = edge == .top || edge == .topLeft || edge == .topRight

        var width = startFrame.width
        var height = startFrame.height
        if affectsRight { width = startFrame.width + dx }
        if affectsLeft { width = startFrame.width - dx }
        if affectsTop { height = startFrame.height + dy }
        if affectsBottom { height = startFrame.height - dy }

        // 以变化更大的轴为准，另一轴按宽高比推导。
        if abs(dx) >= abs(dy) {
            height = width / aspect
        } else {
            width = height * aspect
        }
        width = max(80, width)
        height = max(56, width / aspect)

        var origin = startFrame.origin
        if affectsLeft {
            origin.x = startFrame.maxX - width
        } else if affectsRight {
            origin.x = startFrame.minX
        }
        if affectsBottom {
            origin.y = startFrame.maxY - height
        } else if affectsTop {
            origin.y = startFrame.minY
        }

        window.setFrame(NSRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
    }

    // MARK: - Menu actions

    @objc private func handleOCR() {
        onOCR?()
    }

    @objc private func handleCopy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    @objc private func handleClose() {
        onRequestClose?()
    }
}
