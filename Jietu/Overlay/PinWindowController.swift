import AppKit
import SwiftUI
import VisionKit

/// 「钉图」：把截图钉在屏幕上，作为一个可拖动、可缩放的浮动窗口。
///
/// 支持：
/// - 拖动任意位置移动
/// - 拖动边缘 / 角改变大小（保持宽高比）
/// - 滚轮 / 触控板捏合缩放
/// - 右键菜单：OCR 识别文字、复制图像、关闭
/// - 双击关闭；Esc 关闭；⌘W 快速关闭
/// - 右上角磨砂玻璃关闭按钮（悬停显示）
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
    ///   为 nil 时按原始大小钉在**屏幕正中**。
    static func pin(image: CGImage, on screen: NSScreen?, targetFrame: CGRect? = nil) {
        let controller = PinWindowController(image: image, screen: screen, targetFrame: targetFrame)
        controllers.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            // 钉在屏幕正中；每多钉一张向右下错开一点，避免完全重叠。
            let offset = CGFloat(PinWindowController.controllers.count % 6) * 24
            let origin = CGPoint(
                x: visible.midX - size.width / 2 + offset,
                y: visible.midY - size.height / 2 - offset
            )
            frame = NSRect(origin: origin, size: size)
        }

        content = PinContentView(frame: NSRect(origin: .zero, size: frame.size), image: image)
        window = PinPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.contentView = content
        window.initialFirstResponder = content
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        // 禁用系统自动拖动，由 PinContentView 自行区分边缘调整与内容拖拽。
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true

        content.onRequestClose = { [weak self] in self?.close() }

        // Esc / ⌘W 快捷关闭当前 key 钉图浮窗
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
                self.close()
                return nil
            }
            return event
        }
    }

    private func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        window.orderOut(nil)
        PinWindowController.controllers.removeAll { $0 === self }
        // 若还有剩余钉图，激活上一张为 key window
        PinWindowController.controllers.last?.window.makeKeyAndOrderFront(nil)
    }

}

/// 无边框但可成为 key 的钉图面板。
///
/// @author ixxxxoooo
final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) {
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return false
    }

    override func performClose(_ sender: Any?) {
        (contentView as? PinContentView)?.onRequestClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        (contentView as? PinContentView)?.onRequestClose?()
    }
}

/// 钉图的绘制与交互载体。
///
/// 用自绘而非 `NSImageView`：需要自己处理移动、边缘缩放与缩放，避免和系统
/// 的窗口拖拽 / 缩放行为冲突。
///
/// @author ixxxxoooo
final class PinContentView: NSView {
    let cgImage: CGImage
    private let nsImage: NSImage
    private var activeHandle: SelectionHandle?
    private var isDraggingWindow = false
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    private var trackingArea: NSTrackingArea?

    var onRequestClose: (() -> Void)?

    private var closeButtonHost: NSHostingView<GlassCircleButton>?
    private var liveTextOverlay: ImageAnalysisOverlayView?
    private let liveTextDelegate = PinLiveTextDelegate()
    private let liveTextButton = NSButton()
    private var isLiveTextOn = false

    init(frame: NSRect, image: CGImage) {
        self.cgImage = image
        self.nsImage = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .duringViewResize
        configureCloseButton()
        configureLiveTextButton()

        // 若鼠标当前已落在窗口范围内，初始就展示浮动按钮
        let currentMouse = NSEvent.mouseLocation
        if frame.contains(currentMouse) {
            closeButtonHost?.isHidden = false
            liveTextButton.isHidden = false
        }

        let doubleClick = NSClickGestureRecognizer(
            target: self,
            action: #selector(handleDoubleClick)
        )
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }

    @objc private func handleDoubleClick() {
        onRequestClose?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let closeButtonHost, !closeButtonHost.isHidden, closeButtonHost.frame.contains(point) {
            let localPoint = convert(point, to: closeButtonHost)
            return closeButtonHost.hitTest(localPoint) ?? closeButtonHost
        }
        if !liveTextButton.isHidden, liveTextButton.frame.contains(point) {
            let localPoint = convert(point, to: liveTextButton)
            return liveTextButton.hitTest(localPoint) ?? liveTextButton
        }
        // 边缘手柄检测区优先由 PinContentView 响应，避免被全屏覆盖的实况文本视图拦截
        if PinGeometry.handle(at: point, in: bounds) != nil {
            return self
        }
        return super.hitTest(point)
    }

    /// 键盘快捷键响应：⌘W 关闭、⌘C 复制、⌘0 恢复实际大小
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w":
                onRequestClose?()
                return true
            case "c":
                handleCopy()
                return true
            case "0":
                handleActualSize()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onRequestClose?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        nsImage.draw(in: bounds)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Tracking & Cursors

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        discardCursorRects()
        let tolerance = PinGeometry.defaultEdgeTolerance
        let corner = PinGeometry.defaultCornerTolerance
        let w = bounds.width
        let h = bounds.height
        guard w > corner * 2, h > corner * 2 else { return }

        // 4 角
        addCursorRect(CGRect(x: 0, y: h - corner, width: corner, height: corner), cursor: SelectionCursor.cursor(for: .topLeft))
        addCursorRect(CGRect(x: w - corner, y: h - corner, width: corner, height: corner), cursor: SelectionCursor.cursor(for: .topRight))
        addCursorRect(CGRect(x: 0, y: 0, width: corner, height: corner), cursor: SelectionCursor.cursor(for: .bottomLeft))
        addCursorRect(CGRect(x: w - corner, y: 0, width: corner, height: corner), cursor: SelectionCursor.cursor(for: .bottomRight))

        // 4 边
        addCursorRect(CGRect(x: corner, y: h - tolerance, width: w - corner * 2, height: tolerance), cursor: SelectionCursor.cursor(for: .top))
        addCursorRect(CGRect(x: corner, y: 0, width: w - corner * 2, height: tolerance), cursor: SelectionCursor.cursor(for: .bottom))
        addCursorRect(CGRect(x: 0, y: corner, width: tolerance, height: h - corner * 2), cursor: SelectionCursor.cursor(for: .left))
        addCursorRect(CGRect(x: w - tolerance, y: corner, width: tolerance, height: h - corner * 2), cursor: SelectionCursor.cursor(for: .right))
    }

    private func updateCursor(at point: CGPoint) {
        if let closeButtonHost, !closeButtonHost.isHidden, closeButtonHost.frame.contains(point) {
            NSCursor.arrow.set()
        } else if !liveTextButton.isHidden, liveTextButton.frame.contains(point) {
            NSCursor.arrow.set()
        } else if let handle = activeHandle {
            SelectionCursor.cursor(for: handle).set()
        } else if let handle = PinGeometry.handle(at: point, in: bounds) {
            SelectionCursor.cursor(for: handle).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) && !isLiveTextOn {
            if closeButtonHost?.isHidden == true { closeButtonHost?.isHidden = false }
            if liveTextButton.isHidden { liveTextButton.isHidden = false }
        }
        updateCursor(at: point)
    }

    // MARK: - Mouse Dragging & Resizing

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        guard let window else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if let handle = PinGeometry.handle(at: point, in: bounds) {
            activeHandle = handle
            isDraggingWindow = false
            startFrame = window.frame
            startMouse = NSEvent.mouseLocation
            SelectionCursor.cursor(for: handle).set()
        } else {
            activeHandle = nil
            isDraggingWindow = true
            startFrame = window.frame
            startMouse = NSEvent.mouseLocation
            NSCursor.arrow.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }

        let currentMouse = NSEvent.mouseLocation
        if let handle = activeHandle {
            let aspectRatio = CGFloat(cgImage.width) / CGFloat(cgImage.height)
            let newFrame = PinGeometry.resizedFrame(
                startFrame: startFrame,
                handle: handle,
                startMouse: startMouse,
                currentMouse: currentMouse,
                aspectRatio: aspectRatio
            )
            window.setFrame(newFrame, display: true, animate: false)
            window.invalidateShadow()
            window.invalidateCursorRects(for: self)
            SelectionCursor.cursor(for: handle).set()
        } else if isDraggingWindow {
            let dx = currentMouse.x - startMouse.x
            let dy = currentMouse.y - startMouse.y
            let newOrigin = CGPoint(x: startFrame.origin.x + dx, y: startFrame.origin.y + dy)
            window.setFrameOrigin(newOrigin)
        }
    }

    override func mouseUp(with event: NSEvent) {
        activeHandle = nil
        isDraggingWindow = false
        window?.invalidateShadow()
        window?.invalidateCursorRects(for: self)
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: - Mouse Zoom (Wheel & Pinch)

    override func scrollWheel(with event: NSEvent) {
        guard let window else {
            super.scrollWheel(with: event)
            return
        }

        let delta: CGFloat
        if event.hasPreciseScrollingDeltas {
            delta = event.scrollingDeltaY * 0.005
        } else {
            delta = event.deltaY * 0.05
        }

        guard abs(delta) > 0.0001 else { return }

        let factor = max(0.2, min(5.0, 1.0 + delta))
        zoom(by: factor, mouseInWindow: event.locationInWindow)
    }

    override func magnify(with event: NSEvent) {
        guard let window else {
            super.magnify(with: event)
            return
        }

        let factor = 1.0 + event.magnification
        guard factor > 0.01 else { return }
        zoom(by: factor, mouseInWindow: event.locationInWindow)
    }

    private func zoom(by factor: CGFloat, mouseInWindow: CGPoint) {
        guard let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 2560, height: 1600)
        let maxSize = CGSize(width: visible.width * 3, height: visible.height * 3)

        let newFrame = PinGeometry.zoomedFrame(
            currentFrame: window.frame,
            factor: factor,
            mouseLocationInWindow: mouseInWindow,
            aspectRatio: CGFloat(cgImage.width) / CGFloat(cgImage.height),
            maxSize: maxSize
        )

        window.setFrame(newFrame, display: true, animate: false)
        window.invalidateShadow()
        window.invalidateCursorRects(for: self)
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "PinMenu")

        let copyItem = NSMenuItem(
            title: "复制图像",
            action: #selector(handleCopy),
            keyEquivalent: "c"
        )
        copyItem.target = self
        menu.addItem(copyItem)

        let actualSizeItem = NSMenuItem(
            title: "实际大小 (100%)",
            action: #selector(handleActualSize),
            keyEquivalent: "0"
        )
        actualSizeItem.target = self
        menu.addItem(actualSizeItem)

        menu.addItem(NSMenuItem.separator())

        let liveTextTitle = isLiveTextOn ? "退出实况文本" : "实况文本"
        let liveTextItem = NSMenuItem(
            title: liveTextTitle,
            action: #selector(toggleLiveText),
            keyEquivalent: ""
        )
        liveTextItem.target = self
        menu.addItem(liveTextItem)

        menu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(
            title: "关闭",
            action: #selector(handleClose),
            keyEquivalent: "w"
        )
        closeItem.target = self
        menu.addItem(closeItem)

        return menu
    }

    @objc private func handleActualSize() {
        guard let window else { return }
        let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2
        let naturalSize = CGSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        )
        let currentFrame = window.frame
        let origin = CGPoint(
            x: currentFrame.midX - naturalSize.width / 2,
            y: currentFrame.midY - naturalSize.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: naturalSize), display: true, animate: true)
        window.invalidateShadow()
        window.invalidateCursorRects(for: self)
    }

    // MARK: - Close & Live Text Buttons

    private func configureCloseButton() {
        let button = GlassCircleButton(
            title: "关闭 (⌘W)",
            systemImage: "xmark",
            diameter: 28,
            tint: Theme.Colors.textPrimary,
            action: { [weak self] in
                self?.onRequestClose?()
            }
        )
        let host = NSHostingView(rootView: button)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.isHidden = true
        addSubview(host)
        self.closeButtonHost = host
    }

    private func configureLiveTextButton() {
        liveTextButton.isBordered = false
        liveTextButton.image = NSImage(
            systemSymbolName: "text.viewfinder",
            accessibilityDescription: "实况文本"
        )
        liveTextButton.imagePosition = .imageOnly
        liveTextButton.contentTintColor = .white
        liveTextButton.target = self
        liveTextButton.action = #selector(toggleLiveText)
        liveTextButton.wantsLayer = true
        liveTextButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        liveTextButton.layer?.cornerRadius = 7
        liveTextButton.layer?.masksToBounds = true
        liveTextButton.isHidden = true
        addSubview(liveTextButton)
    }

    override func layout() {
        super.layout()
        let size: CGFloat = 28
        let padding: CGFloat = 8
        closeButtonHost?.frame = CGRect(
            x: bounds.maxX - size - padding,
            y: bounds.maxY - size - padding,
            width: size,
            height: size
        )
        liveTextButton.frame = CGRect(
            x: bounds.maxX - size - padding,
            y: bounds.minY + padding,
            width: size,
            height: size
        )
    }

    override func mouseEntered(with event: NSEvent) {
        if !isLiveTextOn {
            closeButtonHost?.isHidden = false
            liveTextButton.isHidden = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        let mouseInView = convert(event.locationInWindow, from: nil)
        if !bounds.contains(mouseInView) {
            closeButtonHost?.isHidden = true
            liveTextButton.isHidden = true
            NSCursor.arrow.set()
        }
    }

    /// 点击才进入实况文本；默认拖动是移动窗口。
    @objc private func toggleLiveText() {
        if isLiveTextOn {
            stopLiveText()
        } else {
            startLiveText()
        }
    }

    private func startLiveText() {
        guard liveTextOverlay == nil else { return }
        isLiveTextOn = true
        liveTextButton.isHidden = true
        closeButtonHost?.isHidden = true

        let overlay = ImageAnalysisOverlayView(liveTextDelegate)
        overlay.preferredInteractionTypes = .textSelection
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        let topView = closeButtonHost ?? liveTextButton
        addSubview(overlay, positioned: .below, relativeTo: topView)
        liveTextOverlay = overlay

        Task { @MainActor in
            guard ImageAnalyzer.isSupported else { return }
            let analyzer = ImageAnalyzer()
            let configuration = ImageAnalyzer.Configuration(.text)
            if let analysis = try? await analyzer.analyze(
                cgImage,
                orientation: .up,
                configuration: configuration
            ) {
                overlay.analysis = analysis
            }
        }
    }

    private func stopLiveText() {
        liveTextOverlay?.removeFromSuperview()
        liveTextOverlay = nil
        isLiveTextOn = false
        liveTextButton.isHidden = true
        closeButtonHost?.isHidden = true
    }

    @objc private func handleExitLiveText() {
        stopLiveText()
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


/// 实况文本覆盖层的 contentsRect 提供者（覆盖整张图）。
///
/// @author ixxxxoooo
final class PinLiveTextDelegate: NSObject, ImageAnalysisOverlayViewDelegate {
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}
