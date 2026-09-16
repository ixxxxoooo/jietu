import AppKit
import VisionKit

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
        window = PinPanel(
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
        // 交给系统做「拖动窗口」，我们只额外处理边缘缩放。
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true

        content.onRequestClose = { [weak self] in self?.close() }

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

}

/// 无边框但可成为 key 的钉图面板。
///
/// @author ixxxxoooo
final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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

    private var liveTextOverlay: ImageAnalysisOverlayView?
    private let liveTextDelegate = PinLiveTextDelegate()
    private let liveTextButton = NSButton()
    private var isLiveTextOn = false

    private let edgeTolerance: CGFloat = 7

    init(frame: NSRect, image: CGImage) {
        self.cgImage = image
        self.nsImage = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        configureLiveTextButton()

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

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ⌘W 关掉这张钉图（和普通窗口一致）。
    ///
    /// 用 `performKeyEquivalent` 而不是全局监视器：它只在**钉图是 key window** 时被派发，
    /// 所以不会把设置窗口 / 编辑器窗口的 ⌘W 抢走。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            onRequestClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

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
            options: [
                .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Live Text

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
        liveTextButton.frame = CGRect(
            x: bounds.maxX - size - 10,
            y: bounds.minY + 10,
            width: size,
            height: size
        )
    }

    override func mouseEntered(with event: NSEvent) {
        if !isLiveTextOn { liveTextButton.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        liveTextButton.isHidden = true
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

        let overlay = ImageAnalysisOverlayView(liveTextDelegate)
        overlay.preferredInteractionTypes = .textSelection
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay, positioned: .below, relativeTo: liveTextButton)
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
