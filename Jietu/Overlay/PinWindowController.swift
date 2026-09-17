import AppKit
import QuartzCore
import VisionKit

/// 「钉图」：把截图钉在屏幕上，作为一个可拖动、可缩放的浮动窗口。
///
/// 外观是 macOS 自己那个截图预览窗口的样子（见 `PreviewCard`）：截图不贴边，
/// 外面留一圈大圆角玻璃外框；四个角上悬停浮出玻璃按钮。
///
/// 支持：
/// - 拖动任意位置移动
/// - 拖动边缘 / 角改变大小（保持宽高比）
/// - 滚轮 / 触控板捏合缩放
/// - 右键菜单：识别文本、翻译、复制图像、关闭
/// - 双击关闭；Esc 关闭；⌘W 快速关闭
/// - 右上角磨砂玻璃关闭按钮（悬停显示；进入识别文本后常驻）
/// - 左上角编辑按钮：点一下回到标注编辑器（钉图关掉，编辑器用同一张图打开）
/// - 左下角翻译按钮：识别图上的文字，交给 **macOS 自己的翻译面板**（Translation.framework）
/// - 右下角识别文本按钮：点开即选中态，按钮转成 macOS 那颗蓝底实心样式；再点一次退出
///
/// @author ixxxxoooo
final class PinWindowController: NSObject {
    private static var controllers: [PinWindowController] = []

    /// 点了钉图上的「编辑」：把图与钉图的位置交给外面（`AppDelegate` 据此开标注编辑器）。
    ///
    /// 钉图本身不碰编辑器——它连 AppDelegate 都不该知道；这条闭包由 AppDelegate 在启动时接上。
    static var onRequestEdit: ((CGImage, CGRect) -> Void)?

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

        // 卡片外框那一圈不算截图：所有尺寸都先按内容算，再包上 `PreviewCard.inset`。
        let inset = PreviewCard.inset
        let frame: NSRect
        if let targetFrame, targetFrame.width > 1, targetFrame.height > 1 {
            // 原地钉图：给的是截图该占的位置与大小，外框往外扩一圈（图不挪地方）。
            frame = targetFrame.insetBy(dx: -inset, dy: -inset)
        } else {
            // 默认按**原始大小**显示：像素尺寸除以屏幕缩放。超过屏幕 90% 才等比缩小。
            let backingScale = target?.backingScaleFactor ?? 2
            let naturalSize = CGSize(
                width: CGFloat(image.width) / backingScale,
                height: CGFloat(image.height) / backingScale
            )
            let maxSize = CGSize(
                width: visible.width * 0.9 - inset * 2,
                height: visible.height * 0.9 - inset * 2
            )
            let scale = min(
                1,
                min(maxSize.width / naturalSize.width, maxSize.height / naturalSize.height)
            )
            let size = PreviewCard.cardSize(
                forContent: CGSize(
                    width: naturalSize.width * scale,
                    height: naturalSize.height * scale
                )
            )
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
        content.onRequestEdit = { [weak self] in self?.requestEdit() }

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
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "e" {
                self.requestEdit()
                return nil
            }
            return event
        }
    }

    /// 「编辑」：先把钉图收掉，再把图交给外面开编辑器（回到编辑器的感觉，不留一张重复的钉图）。
    private func requestEdit() {
        let frame = window.frame
        close()
        PinWindowController.onRequestEdit?(content.cgImage, frame)
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
    /// 截图本身。尺寸按**内容区**给（窗口比它大一圈外框）。
    private let nsImage: NSImage
    private var activeHandle: SelectionHandle?
    private var isDraggingWindow = false
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    private var trackingArea: NSTrackingArea?

    var onRequestClose: (() -> Void)?
    /// 点了左上角的「编辑」：回到标注编辑器（由 `PinWindowController` 转出去）。
    var onRequestEdit: (() -> Void)?

    /// 卡片外框（截图底下那层玻璃 + 描边）。
    private let chrome = PreviewCardChrome()
    /// 截图本身，单独一层视图。
    private let imageView: PinImageView
    private var editButton: GlassControlButton?
    private var closeButton: GlassControlButton?
    private var liveTextOverlay: ImageAnalysisOverlayView?
    private let liveTextDelegate = PinLiveTextDelegate()
    private var liveTextButton: GlassControlButton?
    private var isLiveTextOn = false

    /// 左下角「翻译」。
    private var translateButton: GlassControlButton?
    /// 系统翻译面板（macOS 自己的翻译 UI），只在第一次点「翻译」时挂上。
    private let translationPresenter = SystemTranslationPresenter()
    private var translationHostInstalled = false
    private var isTranslating = false
    /// 识别过的原文（同一张图只用识别一次）。
    private var recognizedText: String?

    /// 截图在窗口里的矩形（原点左下）。
    private var contentRect: NSRect { PreviewCard.contentRect(in: bounds) }

    init(frame: NSRect, image: CGImage) {
        self.cgImage = image
        let contentSize = PreviewCard.contentRect(in: NSRect(origin: .zero, size: frame.size)).size
        let nsImage = NSImage(cgImage: image, size: contentSize)
        self.nsImage = nsImage
        self.imageView = PinImageView(image: nsImage)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        addSubview(chrome)
        imageView.frame = contentRect
        addSubview(imageView)
        configureEditButton()
        configureCloseButton()
        configureLiveTextButton()
        configureTranslateButton()

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
        if let translateButton, !translateButton.isHidden, translateButton.frame.contains(point) {
            return translateButton
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
        // 截图不在这里画：`draw` 落在子视图**下面**，卡片玻璃（子视图）会把它糊掉。
        // 见 `PinImageView`。
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
        } else if let translateButton, !translateButton.isHidden,
            translateButton.frame.contains(point) {
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

    /// 四个角上浮动按钮（编辑 / 关闭 / 翻译 / 识别文本）的统一显隐入口。
    private func setFloatingButtonsVisible(_ visible: Bool) {
        editButton?.isHidden = !visible
        closeButton?.isHidden = !visible
        liveTextButton?.isHidden = !visible
        translateButton?.isHidden = !visible
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
        translateButton?.setHovering(
            translateButton.map { !$0.isHidden && $0.frame.contains(point) } ?? false
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
        if let translateButton {
            NSLog(
                "[Jietu] pin mouseDown at \(point) translateHidden=\(translateButton.isHidden) translateFrame=\(translateButton.frame)"
            )
        }
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
        if let translateButton, !translateButton.isHidden, translateButton.frame.contains(point) {
            handleTranslate()
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
                aspectRatio: aspectRatio,
                contentInset: PreviewCard.inset
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
            contentInset: PreviewCard.inset,
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

        let liveTextTitle = isLiveTextOn ? "退出识别文本" : "识别文本"
        let liveTextItem = NSMenuItem(
            title: liveTextTitle,
            action: #selector(toggleLiveText),
            keyEquivalent: ""
        )
        liveTextItem.target = self
        menu.addItem(liveTextItem)

        let translateItem = NSMenuItem(
            title: "翻译…",
            action: #selector(handleTranslate),
            keyEquivalent: ""
        )
        translateItem.target = self
        menu.addItem(translateItem)

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
        let naturalSize = PreviewCard.cardSize(
            forContent: CGSize(
                width: CGFloat(cgImage.width) / scale,
                height: CGFloat(cgImage.height) / scale
            )
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

    private func configureEditButton() {
        let button = GlassControlButton(
            symbol: "square.and.pencil",
            diameter: 28,
            tooltip: "编辑 (⌘E)"
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
            tooltip: "关闭 (⌘W)"
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
            tooltip: "识别文本"
        )
        button.onClick = { [weak self] in
            self?.toggleLiveText()
        }
        button.isHidden = true
        addSubview(button)
        self.liveTextButton = button
    }

    /// 左下角「翻译」：胶囊 + 图标 + 文字（与浮窗中央那颗「保存」同一套外形）。
    private func configureTranslateButton() {
        let button = GlassControlButton(
            symbol: "translate",
            labelText: "翻译",
            diameter: 28,
            tooltip: "翻译（用 macOS 自己的翻译）"
        )
        button.onClick = { [weak self] in
            self?.handleTranslate()
        }
        button.isHidden = true
        addSubview(button)
        self.translateButton = button
    }

    override func layout() {
        super.layout()
        chrome.frame = bounds
        imageView.frame = contentRect
        let size: CGFloat = 28
        let padding: CGFloat = 8
        // 四角各一个：左上编辑、右上关闭、左下翻译、右下识别文本。
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
        if let translateButton {
            let translateSize = translateButton.preferredSize
            translateButton.frame = CGRect(
                x: bounds.minX + padding,
                y: bounds.minY + padding,
                width: translateSize.width,
                height: translateSize.height
            )
        }
        // 识别文本的覆盖层只盖截图那块：卡片外框不是图，别把文字层画到框上去。
        liveTextOverlay?.frame = contentRect
        // 翻译面板从「翻译」按钮那块长出来。
        translationPresenter.updateAnchor(translateButton?.frame ?? .zero)
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
        translateButton?.setHovering(false)
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
        liveTextButton?.toolTip = "退出识别文本"
        liveTextButton?.isActive = true
        // macOS 那颗 Live Text 按钮亮着就是蓝底实心。
        liveTextButton?.prominence = .accent

        let overlay = ImageAnalysisOverlayView(liveTextDelegate)
        overlay.preferredInteractionTypes = .textSelection
        overlay.frame = contentRect
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
        translateButton?.isHidden = true
    }

    @objc private func handleExitLiveText() {
        stopLiveText()
    }

    // MARK: - 翻译（macOS 自己的翻译）

    /// 点「翻译」：先认出图上的字，再把原文交给 **macOS 自己的翻译面板**
    /// （`translationPresentation`，弹出来就是系统那个能选语言、能朗读的翻译框）。
    ///
    /// 跟 macOS 预览窗口的「翻译」按钮一个路子——它也是先 Live Text 认字再翻译。
    @objc func handleTranslate() {
        NSLog("[Jietu] handleTranslate entered (isTranslating=\(isTranslating))")
        guard !isTranslating else { return }
        if let recognizedText {
            presentSystemTranslation(recognizedText)
            return
        }

        isTranslating = true
        translateButton?.toolTip = "正在识别…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let text = await OCRService.recognizeText(in: self.cgImage)
            self.isTranslating = false
            self.translateButton?.toolTip = "翻译（用 macOS 自己的翻译）"
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                self.presentNothingToTranslate()
                return
            }
            self.recognizedText = trimmed
            self.presentSystemTranslation(trimmed)
        }
    }

    private func presentSystemTranslation(_ text: String) {
        // 面板是系统弹窗，得让 App 在最前面，弹出来才看得见。
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if translationHostInstalled == false {
            translationPresenter.attach(to: self, anchor: translateButton?.frame ?? .zero)
            translationHostInstalled = true
        }
        translationPresenter.updateAnchor(translateButton?.frame ?? .zero)
        translationPresenter.present(text: text)
    }

    private func presentNothingToTranslate() {
        let alert = NSAlert()
        alert.messageText = "没识别到文字"
        alert.informativeText = "这张图里没有可以翻译的文字。"
        alert.addButton(withTitle: "好")
        alert.runModal()
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

    /// 测试用：截图在窗口里的矩形（窗口比它大一圈外框）。
    var contentRectForTesting: NSRect { contentRect }

    /// 测试用：左下角「翻译」按钮。
    var translateButtonForTesting: GlassControlButton? { translateButton }

    /// 测试用：右下角「识别文本」按钮。
    var liveTextButtonForTesting: GlassControlButton? { liveTextButton }

    /// 测试用：预置「已识别的原文」，免去真跑一次 OCR。
    func presetRecognizedText(_ text: String) {
        recognizedText = text
    }

    /// 测试用：交给系统翻译的原文（没点过「翻译」是空串）。
    var presentedTranslationText: String { translationPresenter.presentedText }

    /// 测试用：系统翻译面板的宿主是不是挂上了。
    var isTranslationHostAttached: Bool { translationHostInstalled }

    /// 测试用：识别出来的原文（nil = 还没识别过）。空串说明图里没字。
    var recognizedTextForTesting: String? { recognizedText }

    /// 测试用：系统翻译面板是不是**我们要求弹出**了（SwiftUI 那边有没有接手另说）。
    var isSystemTranslationPresented: Bool { translationPresenter.isPresented }
}


/// 卡片里那层截图。
///
/// 必须是**子视图**：AppKit 里父视图自己的 `draw` 永远落在子视图下面，
/// 卡片底板（玻璃）也是子视图——截图要是还画在 `PinContentView.draw` 里，
/// 就会被那层玻璃盖住、整张图被洗成一片模糊的白（自检截图里一眼就看出来了）。
///
/// @author ixxxxoooo
final class PinImageView: NSView {
    let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 截图不参与命中：命中一律交给宿主（拖动 / 缩放手柄 / 四角按钮都在那儿判定）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: PreviewCard.contentRadius,
            yRadius: PreviewCard.contentRadius
        )
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        // 截图自己那圈发丝描边：白图 / 深图都从外框里「浮」出来（macOS 预览窗口同款）。
        path.lineWidth = Theme.Size.hairline
        NSColor.jietuCardStroke.setStroke()
        path.stroke()
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
