import AppKit
import SwiftUI
import VisionKit

final class PinContentView: NSView {
    let cgImage: CGImage
    private let nsImage: NSImage
    private var activeHandle: SelectionHandle?
    private var isDraggingWindow = false
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    private var trackingArea: NSTrackingArea?

    var onRequestClose: (() -> Void)?
    /// 点了左上角的「编辑」：回到标注编辑器（由 `PinWindowController` 转出去）。
    var onRequestEdit: (() -> Void)?

    private var editButton: GlassControlButton?
    private var closeButton: GlassControlButton?
    private var liveTextOverlay: ImageAnalysisOverlayView?
    private let liveTextDelegate = PinLiveTextDelegate()
    private var liveTextButton: GlassControlButton?
    private var isLiveTextOn = false

    init(frame: NSRect, image: CGImage) {
        self.cgImage = image
        self.nsImage = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PinGeometry.defaultCornerRadius
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .duringViewResize
        configureEditButton()
        configureCloseButton()
        configureLiveTextButton()

        // 若鼠标当前已落在窗口范围内，初始就展示浮动按钮
        if frame.contains(NSEvent.mouseLocation) {
            setFloatingButtonsVisible(true)
        }
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
        if let editButton, !editButton.isHidden, editButton.frame.contains(point) {
            return editButton
        }
        if let closeButton, !closeButton.isHidden, closeButton.frame.contains(point) {
            return closeButton
        }
        if let liveTextButton, !liveTextButton.isHidden, liveTextButton.frame.contains(point) {
            return liveTextButton
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
        if let editButton, !editButton.isHidden, editButton.frame.contains(point) {
            NSCursor.arrow.set()
        } else if let closeButton, !closeButton.isHidden, closeButton.frame.contains(point) {
            NSCursor.arrow.set()
        } else if let liveTextButton, !liveTextButton.isHidden, liveTextButton.frame.contains(point) {
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
        if bounds.contains(point) {
            setFloatingButtonsVisible(true)
        }
        updateButtonHover(at: point)
        updateCursor(at: point)
    }

    // MARK: - Floating Buttons

    /// 四个角上浮动按钮（编辑 / 关闭 / 识别文本）的统一显隐入口。
    private func setFloatingButtonsVisible(_ visible: Bool) {
        editButton?.isHidden = !visible
        closeButton?.isHidden = !visible
        liveTextButton?.isHidden = !visible
    }

    /// 依鼠标是否落在窗口内刷新浮动按钮；无窗口（构造期 / 测试）时保持原状。
    private func refreshFloatingButtons() {
        guard let window else { return }
        setFloatingButtonsVisible(window.frame.contains(NSEvent.mouseLocation))
    }

    /// 圆形按钮的悬停态统一在这里算：宿主视图的 tracking 比按钮自己的更可靠
    /// （按钮自 `isHidden` 切换后不一定重建 tracking area）。
    private func updateButtonHover(at point: NSPoint) {
        editButton?.setHovering(
            editButton.map { !$0.isHidden && $0.frame.contains(point) } ?? false
        )
        closeButton?.setHovering(
            closeButton.map { !$0.isHidden && $0.frame.contains(point) } ?? false
        )
        liveTextButton?.setHovering(
            liveTextButton.map { !$0.isHidden && $0.frame.contains(point) } ?? false
        )
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
        if let editButton, !editButton.isHidden, editButton.frame.contains(point) {
            onRequestEdit?()
            return
        }
        if let closeButton, !closeButton.isHidden, closeButton.frame.contains(point) {
            onRequestClose?()
            return
        }
        if let liveTextButton, !liveTextButton.isHidden, liveTextButton.frame.contains(point) {
            toggleLiveText()
            return
        }

        // 双击关闭。用 clickCount 而不是 `NSClickGestureRecognizer`：后者为了判断是不是双击，
        // 会把单击的鼠标事件压后一个双击间隔才交给视图（实测关窗要晚 ~520ms）。
        if event.clickCount == 2 {
            onRequestClose?()
            return
        }

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
        guard window != nil else {
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
        guard window != nil else {
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
            title: L10n.pinCopyImage,
            action: #selector(handleCopy),
            keyEquivalent: "c"
        )
        copyItem.target = self
        menu.addItem(copyItem)

        let actualSizeItem = NSMenuItem(
            title: L10n.pinActualSize,
            action: #selector(handleActualSize),
            keyEquivalent: "0"
        )
        actualSizeItem.target = self
        menu.addItem(actualSizeItem)

        let editItem = NSMenuItem(
            title: L10n.pinEdit,
            action: #selector(handleEdit),
            keyEquivalent: "e"
        )
        editItem.target = self
        menu.addItem(editItem)

        menu.addItem(NSMenuItem.separator())

        let liveTextTitle = isLiveTextOn ? L10n.pinLiveTextOn : L10n.pinLiveTextOff
        let liveTextItem = NSMenuItem(
            title: liveTextTitle,
            action: #selector(toggleLiveText),
            keyEquivalent: ""
        )
        liveTextItem.target = self
        menu.addItem(liveTextItem)

        menu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(
            title: L10n.pinClose,
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

    @objc private func handleEdit() {
        onRequestEdit?()
    }

    // MARK: - Close & Live Text Buttons

    private func configureEditButton() {
        let button = GlassControlButton(
            symbol: "square.and.pencil",
            diameter: 28,
            tooltip: L10n.pinEditTooltip
        )
        button.onClick = { [weak self] in
            self?.onRequestEdit?()
        }
        button.isHidden = true
        addSubview(button)
        self.editButton = button
    }

    private func configureCloseButton() {
        let button = GlassControlButton(
            symbol: "xmark",
            diameter: 28,
            tooltip: L10n.pinCloseTooltip
        )
        button.onClick = { [weak self] in
            self?.onRequestClose?()
        }
        button.isHidden = true
        addSubview(button)
        self.closeButton = button
    }

    /// 识别文本：`text.viewfinder`，跟 macOS 那颗 Live Text 按钮同一个图标。
    ///
    /// 关着是普通玻璃圆盘，点亮后换成**蓝底白图标的实心**（`prominence = .accent`）——
    /// 「亮着」这件事由外形直接说，不用再挂个勾。
    private func configureLiveTextButton() {
        let button = GlassControlButton(
            symbol: "text.viewfinder",
            diameter: 28,
            tooltip: L10n.pinLiveTextTooltip
        )
        button.onClick = { [weak self] in
            self?.toggleLiveText()
        }
        button.isHidden = true
        addSubview(button)
        self.liveTextButton = button
    }

    override func layout() {
        super.layout()
        let size: CGFloat = 28
        let padding: CGFloat = 8
        // 四角各一个：左上编辑、右上关闭、右下识别文本。
        editButton?.frame = CGRect(
            x: bounds.minX + padding,
            y: bounds.maxY - size - padding,
            width: size,
            height: size
        )
        closeButton?.frame = CGRect(
            x: bounds.maxX - size - padding,
            y: bounds.maxY - size - padding,
            width: size,
            height: size
        )
        liveTextButton?.frame = CGRect(
            x: bounds.maxX - size - padding,
            y: bounds.minY + padding,
            width: size,
            height: size
        )
        liveTextOverlay?.frame = bounds
    }

    override func mouseEntered(with event: NSEvent) {
        setFloatingButtonsVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        let mouseInView = convert(event.locationInWindow, from: nil)
        // 识别文本下按钮**常驻**：它是「退出识别文本」与「关闭钉图」的唯一可见入口。
        if !bounds.contains(mouseInView), !isLiveTextOn {
            setFloatingButtonsVisible(false)
            NSCursor.arrow.set()
        }
        editButton?.setHovering(false)
        closeButton?.setHovering(false)
        liveTextButton?.setHovering(false)
    }

    /// 点击才进入识别文本；默认拖动是移动窗口。
    @objc func toggleLiveText() {
        if isLiveTextOn {
            stopLiveText()
        } else {
            startLiveText()
        }
    }

    private func startLiveText() {
        guard liveTextOverlay == nil else { return }
        isLiveTextOn = true
        // 按钮不隐藏：覆盖层会接走右键菜单，退出的路只剩这几个按钮。
        // 右上角「关闭」必须一直在（用户明确要求 OCR 时也要能关掉钉图），
        // 右下角「识别文本」留着点回普通态。
        setFloatingButtonsVisible(true)
        liveTextButton?.toolTip = L10n.pinExitLiveText
        liveTextButton?.isActive = true
        // macOS 那颗 Live Text 按钮亮着就是蓝底实心。
        liveTextButton?.prominence = .accent

        let overlay = ImageAnalysisOverlayView(liveTextDelegate)
        overlay.preferredInteractionTypes = .textSelection
        overlay.frame = bounds
        let topView = closeButton ?? liveTextButton
        if let topView {
            addSubview(overlay, positioned: .below, relativeTo: topView)
        } else {
            addSubview(overlay)
        }
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
        liveTextButton?.isActive = false
        liveTextButton?.prominence = .glass
        liveTextButton?.isHidden = true
        closeButton?.isHidden = true
        editButton?.isHidden = true
        // 鼠标还停在钉图上时不会再来一次 mouseEntered，得自己把悬浮按钮请回来。
        refreshFloatingButtons()
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

    // MARK: - 测试钩子

    /// 测试用：右下角「识别文本」按钮。
    var liveTextButtonForTesting: GlassControlButton? { liveTextButton }
}


/// 实况文本覆盖层的 contentsRect 提供者（覆盖整张图）。
///
/// @author ixxxxoooo
