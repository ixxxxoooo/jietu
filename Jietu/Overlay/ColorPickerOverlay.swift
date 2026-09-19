import AppKit
import Observation
import SwiftUI

/// 取色器浮卡的状态（卡片只读它，外面改它就刷新）。
///
/// @author ixxxxoooo
@Observable
final class ColorPickerCardModel {
    var image: CGImage?
    var hex: String?
    var swatch: NSColor?
}

/// 屏幕取色覆盖层：光标走到哪，旁边就挂一条**液态玻璃**读数（放大镜 + 色号），
/// 点一下取色、Esc / 右键取消。
///
/// 为什么不用系统的 `NSColorSampler`：它那套放大镜不透明、样式也改不了，取色时挡住要看的地方。
/// 这里自己搭一层：浮卡是玻璃的、跟着光标走，光标本体周围完全不被遮——
/// 取像素仍然走系统（ScreenCaptureKit），报的色和系统取色器逐字节一致。
///
/// @author ixxxxoooo
@MainActor
final class ColorPickerOverlay {
    /// 结束时回调：选中给结果，取消（Esc / 右键）给 nil。
    var onFinish: ((ScreenPixelProbe.PickedColor?) -> Void)?

    private var panels: [OverlayWindow] = []
    private let model = ColorPickerCardModel()
    private var cardHost: PixelLoupeCardHost<ColorPickerCard>?

    /// 每块屏一个探针，跨屏时按需建（建一次 ~150ms，只在那一下）。
    private var probes: [CGDirectDisplayID: ScreenPixelProbe] = [:]
    private var sampling: Task<Void, Never>?
    private var pendingPoint: CGPoint?

    private var isPresenting = false

    // MARK: - 生命周期

    func present() {
        guard !isPresenting else { return }
        isPresenting = true

        let card = PixelLoupeCardHost(rootView: ColorPickerCard(model: model))
        card.translatesAutoresizingMaskIntoConstraints = true
        cardHost = card

        for screen in NSScreen.screens {
            let panel = makePanel(for: screen)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        // 光标所在那块屏拿键盘焦点（Esc 才有地方落）。
        activePanel()?.makeKey()
        activePanel()?.makeFirstResponder(activePanel()?.contentView)
        handleMove(to: currentLocalPoint())
    }

    func dismiss() {
        guard isPresenting else { return }
        isPresenting = false
        sampling?.cancel()
        sampling = nil
        pendingPoint = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        cardHost = nil
        probes.removeAll()
        model.image = nil
        model.hex = nil
        model.swatch = nil
    }

    // MARK: - 窗 / 视图

    private func makePanel(for screen: NSScreen) -> OverlayWindow {
        // 用 `OverlayWindow`（`nonactivatingPanel` + `canBecomeKey`）：不激活 App 也能拿键盘焦点，
        // 和截图遮罩同一套（见 `OverlayWindow` 的注释）。
        let panel = OverlayWindow(
            contentRect: NSRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.setFrame(screen.frame, display: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false

        let surface = ColorPickerTrackingView(frame: NSRect(origin: .zero, size: screen.frame.size))
        surface.screenFrame = screen.frame
        surface.onMove = { [weak self] localPoint in
            self?.panelDidMove(panel, localPoint: localPoint)
        }
        surface.onPick = { [weak self] localPoint in
            self?.pick(at: localPoint, in: panel)
        }
        surface.onCancel = { [weak self] in self?.finish(nil) }
        panel.contentView = surface
        return panel
    }

    /// 光标在哪块屏上（没有就退回主屏）。
    private func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }

    private func activePanel() -> OverlayWindow? {
        guard let screen = screenUnderMouse(), let index = NSScreen.screens.firstIndex(of: screen)
        else { return panels.first }
        return panels.indices.contains(index) ? panels[index] : panels.first
    }

    /// 光标在该屏内的点（原点左上）。
    private func currentLocalPoint() -> CGPoint {
        guard let panel = activePanel() else { return .zero }
        let location = NSEvent.mouseLocation
        return CGPoint(x: location.x - panel.frame.minX, y: panel.frame.maxY - location.y)
    }

    // MARK: - 跟随 / 采样

    private func panelDidMove(_ panel: OverlayWindow, localPoint: CGPoint) {
        // 光标跑到别的屏了：把键盘焦点（Esc）和卡片搬过去。
        if !panel.isKeyWindow {
            panel.makeKey()
            panel.makeFirstResponder(panel.contentView)
        }
        moveCard(to: panel, localPoint: localPoint)
        pendingPoint = localPoint
        startSamplingIfNeeded(panel: panel)
    }

    private func handleMove(to localPoint: CGPoint) {
        guard let panel = activePanel() else { return }
        moveCard(to: panel, localPoint: localPoint)
        pendingPoint = localPoint
        startSamplingIfNeeded(panel: panel)
    }

    /// 采样循环：一次只飞一个请求，永远只采「最新的那个点」（鼠标甩得快也不排队）。
    private func startSamplingIfNeeded(panel: OverlayWindow) {
        guard sampling == nil else { return }
        sampling = Task { [weak self] in
            while let self, let point = self.pendingPoint, self.isPresenting {
                self.pendingPoint = nil
                await self.refresh(panel: panel, localPoint: point)
            }
            self?.sampling = nil
        }
    }

    private func refresh(panel: OverlayWindow, localPoint: CGPoint) async {
        guard let screen = NSScreen.screens.first(where: { $0.frame == panel.frame }),
            let probe = await probe(for: screen)
        else { return }
        let pixels = CGPoint(
            x: localPoint.x * screen.backingScaleFactor,
            y: localPoint.y * screen.backingScaleFactor
        )
        guard let image = try? await probe.capture(around: pixels) else { return }
        guard isPresenting else { return }
        model.image = image
        if let sample = ScreenPixelProbe.centerSample(of: image) {
            model.hex = sample.hexString
            model.swatch = sample.nsColor
        }
    }

    /// 取探针（第一次用某块屏时现建）。
    private func probe(for screen: NSScreen) async -> ScreenPixelProbe? {
        guard let displayID = screen.jietu_displayID else { return nil }
        if let existing = probes[displayID] { return existing }
        guard let created = try? await ScreenPixelProbe(
            displayID: displayID, scale: screen.backingScaleFactor
        ) else { return nil }
        probes[displayID] = created
        return created
    }

    /// 卡片贴在光标右下角，贴边就翻到另一侧（和截图放大镜同一套摆法）。
    private func moveCard(to panel: OverlayWindow, localPoint: CGPoint) {
        guard let card = cardHost, let surface = panel.contentView else { return }
        if card.superview !== surface { surface.addSubview(card) }
        let size = card.fittingSize
        let gap: CGFloat = PixelLoupe.gap
        let bounds = surface.bounds
        var origin = CGPoint(x: localPoint.x + gap, y: localPoint.y + gap)
        if origin.x + size.width > bounds.maxX - 8 { origin.x = localPoint.x - gap - size.width }
        if origin.y + size.height > bounds.maxY - 8 { origin.y = localPoint.y - gap - size.height }
        origin.x = min(max(origin.x, bounds.minX + 8), max(bounds.minX + 8, bounds.maxX - size.width - 8))
        origin.y = min(max(origin.y, bounds.minY + 8), max(bounds.minY + 8, bounds.maxY - size.height - 8))
        card.frame = NSRect(origin: origin, size: size)
    }

    // MARK: - 取色 / 取消

    private func pick(at localPoint: CGPoint, in panel: OverlayWindow) {
        Task { [weak self] in
            guard let self else { return }
            var picked: ScreenPixelProbe.PickedColor?
            // 点下去再抓一次：报的必须是**按下那一刻**光标下那个像素。
            if let screen = NSScreen.screens.first(where: { $0.frame == panel.frame }),
                let probe = await probe(for: screen)
            {
                let pixels = CGPoint(
                    x: localPoint.x * screen.backingScaleFactor,
                    y: localPoint.y * screen.backingScaleFactor
                )
                if let image = try? await probe.capture(around: pixels),
                    let sample = ScreenPixelProbe.centerSample(of: image)
                {
                    picked = ScreenPixelProbe.PickedColor(hex: sample.hexString, sample: sample)
                }
            }
            finish(picked)
        }
    }

    private func finish(_ picked: ScreenPixelProbe.PickedColor?) {
        dismiss()
        onFinish?(picked)
    }
}
/// 事件面：整屏透明，只负责「报光标位置 / 接点击 / 收 Esc」。
final class ColorPickerTrackingView: NSView {
    var onMove: ((CGPoint) -> Void)?
    var onPick: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    var screenFrame: CGRect = .zero

    /// 坐标用「原点左上」，和卡片摆位 / 像素换算同一套口径，省掉来回翻转。
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        onMove?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        onMove?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        onPick?(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // 53 = Esc
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
