import AppKit
import SwiftUI
import os

/// 遮罩画布：选区状态机 + 全部视觉层。
///
/// 分层设计（性能关键）：整屏冻结图放在**静态**的 `imageLayer` 里永不重绘，
/// 鼠标移动只更新十字线、放大镜、尺寸标签这几个小图层。若把图像画进 `draw(_:)`，
/// 6K 分辨率下每帧都要重新合成整屏，拖动会明显掉帧。
final class OverlayCanvasView: NSView {
    private let logger = Logger(subsystem: "com.liwenjiao.jietu", category: "overlay")

    // MARK: - Inputs

    let snapshot: DisplaySnapshot
    private let session: CaptureSession
    private let displayIndex: Int
    private let displayCount: Int

    // MARK: - Callbacks

    var onCancel: (() -> Void)?
    /// 参数是本显示器 local 坐标（point、原点左下）下的选区。
    var onCommit: ((CGRect) -> Void)?
    /// 键盘命令（↵ / 方向键）必须作用在「鼠标所在那块屏」上，
    /// 而多屏时 key window 只会是最后创建的那个，所以焦点要跟着鼠标走。
    var onFocusRequest: (() -> Void)?

    // MARK: - State

    private enum Interaction {
        case idle
        /// 已按下但还没超过拖拽阈值。
        case pressing(anchor: CGPoint)
        case selecting(anchor: CGPoint)
        /// 已有选区且空闲。
        case settled
        case resizing(handle: SelectionHandle, original: CGRect)
        case moving(grabOffset: CGSize, original: CGRect)
    }

    private var interaction: Interaction = .idle
    private var selection: CGRect?
    private var hoveredWindow: WindowInfo?
    private var cursorPoint: CGPoint?

    private var sampledColor: PixelSampler.Sample?
    private var lastSampledPixel: CGPoint?

    /// 上次用过的选区，按显示器记忆，Tab 恢复。
    private static var rememberedSelection: [CGDirectDisplayID: CGRect] = [:]

    /// 遮罩刚出现时，窗口出现在光标之下会送来一次「按住状态」的杂散 mouseDown
    /// （实测 pressedMouseButtons=1）。用一小段静默期挡掉。
    private var inputArmedAt: TimeInterval = 0

    // MARK: - Inline annotation

    /// 就地编辑模式：选区定下来后不立刻截图，而是在选框下方弹出工具栏就地标注。
    var inlineMode = false
    /// 就地标注完成：参数是已经裁好、并烘焙了标注的最终图，以及选区（local）。
    var onCommitAnnotated: ((CGImage, CGRect) -> Void)?
    /// 进入就地标注时通知 Coordinator（用于同步其它显示器的状态）。
    var onInlineEditingChanged: ((Bool) -> Void)?

    private enum Phase {
        case selecting
        case annotating
    }

    private var phase: Phase = .selecting
    /// 是否正处于就地标注阶段（供 Coordinator 判断 Esc 归属）。
    var isAnnotationPhase: Bool { phase == .annotating }
    private var redoAnnotations: [Annotation] = []
    private var annotations: [Annotation] = []
    private var annotationDraft: Annotation?
    private var previewBase: CGImage?
    private var previewScale: CGFloat = 1
    private var toolbarModel: InlineToolbarModel?
    private var toolbarHost: NSView?
    private var textField: NSTextField?
    private var inlineDragging = false
    private var inlineStart: CGPoint = .zero

    private let annotationLayer = CALayer()

    // MARK: - Layers

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let windowHighlightLayer = CAShapeLayer()
    private let selectionBorderOuterLayer = CAShapeLayer()
    private let selectionBorderInnerLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let magnifierLayer = CALayer()
    private let magnifierRingLayer = CAShapeLayer()
    /// 暗色外环。放大镜里的内容本身可能就是纯白，白环白底会整个消失。
    private let magnifierRingShadowLayer = CAShapeLayer()
    private let magnifierCrosshairLayer = CAShapeLayer()
    /// 十字线的黑色描边层。白线落在白色内容上会「消失」，必须有描边。
    private let magnifierCrosshairShadowLayer = CAShapeLayer()
    private let magnifierPillLayer = CALayer()
    private let magnifierSwatchLayer = CALayer()
    private let magnifierLabelLayer = CATextLayer()
    private let sizeLabelLayer = CATextLayer()
    private let windowLabelLayer = CATextLayer()
    private let hintLayer = CATextLayer()

    private var trackingArea: NSTrackingArea?

    // MARK: - Init

    init(
        snapshot: DisplaySnapshot,
        session: CaptureSession,
        displayIndex: Int,
        displayCount: Int
    ) {
        self.snapshot = snapshot
        self.session = session
        self.displayIndex = displayIndex
        self.displayCount = displayCount
        super.init(frame: NSRect(origin: .zero, size: snapshot.screenFrameInPoints.size))
        wantsLayer = true
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func armInput(after delay: TimeInterval) {
        inputArmedAt = CACurrentMediaTime() + delay
    }

    private var isInputArmed: Bool {
        CACurrentMediaTime() >= inputArmedAt
    }

    private var canvasBounds: CGRect {
        CGRect(origin: .zero, size: snapshot.screenFrameInPoints.size)
    }

    private func requestFocusIfNeeded() {
        guard let window, !window.isKeyWindow else { return }
        onFocusRequest?()
    }

    private var isSettled: Bool {
        if case .settled = interaction { return true }
        return false
    }

    #if DEBUG
    /// 自检用：当前选区（本显示器 local 坐标）。
    var debugSelection: CGRect? { selection }
    #endif

    // MARK: - Layer setup

    private func configureLayers() {
        guard let root = layer else { return }
        let scale = window?.backingScaleFactor ?? snapshot.nominalScaleFactor

        imageLayer.contents = snapshot.image
        imageLayer.contentsGravity = .resize
        imageLayer.contentsScale = scale
        imageLayer.magnificationFilter = .nearest
        imageLayer.frame = bounds
        root.addSublayer(imageLayer)

        // 就地标注层：叠在冻结图之上、压暗层之下（选区被挖空，所以标注可见）。
        annotationLayer.frame = bounds
        annotationLayer.contentsGravity = .resize
        annotationLayer.magnificationFilter = .nearest
        annotationLayer.isHidden = true
        root.addSublayer(annotationLayer)

        dimLayer.fillColor = NSColor.black
            .withAlphaComponent(Theme.overlayDimAlpha).cgColor
        dimLayer.fillRule = .evenOdd
        dimLayer.frame = bounds
        root.addSublayer(dimLayer)

        // 吸附预览（自动识别窗口边界）：绿色粗线描边。
        windowHighlightLayer.fillColor = NSColor(Theme.selectionGreen)
            .withAlphaComponent(0.06).cgColor
        windowHighlightLayer.strokeColor = NSColor(Theme.selectionGreen).cgColor
        windowHighlightLayer.lineWidth = 3
        windowHighlightLayer.isHidden = true
        windowHighlightLayer.frame = bounds
        root.addSublayer(windowHighlightLayer)

        // 绿色虚线选框（参考 CleanShot）。
        configureBorderLayer(selectionBorderOuterLayer, color: NSColor(Theme.selectionGreen))
        selectionBorderOuterLayer.lineWidth = 1.5
        selectionBorderOuterLayer.lineDashPattern = [6, 4]
        configureBorderLayer(selectionBorderInnerLayer, color: .clear)
        root.addSublayer(selectionBorderOuterLayer)
        root.addSublayer(selectionBorderInnerLayer)

        handlesLayer.fillColor = NSColor(Theme.selectionGreen).cgColor
        handlesLayer.strokeColor = NSColor.white.cgColor
        handlesLayer.lineWidth = 1
        handlesLayer.frame = bounds
        root.addSublayer(handlesLayer)

        crosshairLayer.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        crosshairLayer.lineWidth = 1
        crosshairLayer.fillColor = nil
        crosshairLayer.frame = bounds
        root.addSublayer(crosshairLayer)

        configureMagnifier(scale: scale, root: root)

        for textLayer in [sizeLabelLayer, windowLabelLayer, hintLayer] {
            configurePillTextLayer(textLayer, scale: scale)
            root.addSublayer(textLayer)
        }
        windowLabelLayer.isHidden = true

        updateAllLayers()
    }

    private func configureBorderLayer(_ layer: CAShapeLayer, color: NSColor) {
        layer.fillColor = nil
        layer.strokeColor = color.cgColor
        layer.lineWidth = 1
        layer.isHidden = true
        layer.frame = bounds
    }

    private func configurePillTextLayer(_ textLayer: CATextLayer, scale: CGFloat) {
        textLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        textLayer.fontSize = 11
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        textLayer.cornerRadius = 6
        textLayer.masksToBounds = true
        textLayer.alignmentMode = .center
        textLayer.contentsScale = scale
        textLayer.isHidden = true
    }

    private func configureMagnifier(scale: CGFloat, root: CALayer) {
        magnifierLayer.contents = snapshot.image
        magnifierLayer.contentsGravity = .resize
        magnifierLayer.magnificationFilter = .nearest
        magnifierLayer.minificationFilter = .nearest
        magnifierLayer.cornerRadius = Theme.magnifierSize / 2
        magnifierLayer.masksToBounds = true
        magnifierLayer.contentsScale = scale
        magnifierLayer.isHidden = true
        root.addSublayer(magnifierLayer)

        magnifierRingShadowLayer.fillColor = nil
        magnifierRingShadowLayer.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
        magnifierRingShadowLayer.lineWidth = 5
        magnifierRingShadowLayer.isHidden = true
        root.addSublayer(magnifierRingShadowLayer)

        magnifierRingLayer.fillColor = nil
        magnifierRingLayer.strokeColor = NSColor.white.cgColor
        magnifierRingLayer.lineWidth = 2
        magnifierRingLayer.isHidden = true
        root.addSublayer(magnifierRingLayer)

        // 十字线白底白线看不清，用黑色描边垫底。
        magnifierCrosshairShadowLayer.fillColor = nil
        magnifierCrosshairShadowLayer.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
        magnifierCrosshairShadowLayer.lineWidth = 3
        magnifierCrosshairShadowLayer.isHidden = true
        root.addSublayer(magnifierCrosshairShadowLayer)

        magnifierCrosshairLayer.fillColor = nil
        magnifierCrosshairLayer.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        magnifierCrosshairLayer.lineWidth = 1
        magnifierCrosshairLayer.isHidden = true
        root.addSublayer(magnifierCrosshairLayer)
        magnifierPillLayer.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        magnifierPillLayer.cornerRadius = 6
        magnifierPillLayer.isHidden = true
        root.addSublayer(magnifierPillLayer)

        magnifierSwatchLayer.cornerRadius = 3
        magnifierSwatchLayer.borderWidth = 1
        magnifierSwatchLayer.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        magnifierSwatchLayer.isHidden = true
        root.addSublayer(magnifierSwatchLayer)

        magnifierLabelLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        magnifierLabelLayer.fontSize = 11
        magnifierLabelLayer.foregroundColor = NSColor.white.cgColor
        magnifierLabelLayer.alignmentMode = .left
        magnifierLabelLayer.truncationMode = .none
        magnifierLabelLayer.contentsScale = scale
        magnifierLabelLayer.isHidden = true
        root.addSublayer(magnifierLabelLayer)
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? snapshot.nominalScaleFactor
        for layer in [
            imageLayer, dimLayer, windowHighlightLayer, selectionBorderOuterLayer,
            selectionBorderInnerLayer, handlesLayer, crosshairLayer,
        ] {
            layer.frame = bounds
        }
        imageLayer.contentsScale = scale
        // 标注层尺寸由 updateAnnotationLayer() 按选区设置，这里不能重置成整屏。
        annotationLayer.contentsScale = scale
        for textLayer in [sizeLabelLayer, windowLabelLayer, hintLayer, magnifierLabelLayer] {
            textLayer.contentsScale = scale
        }
        updateAllLayers()
        updateToolbarPosition()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                .activeAlways, .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Rendering

    private func updateAllLayers() {
        updateDimPath()
        updateSelectionLayers()
        updateCrosshair()
        updateMagnifier()
        updateHint()
    }

    private func updateDimPath() {
        let path = CGMutablePath()
        path.addRect(bounds)
        // even-odd 挖洞：有选区就挖选区，没选区但吸附到窗口就挖那个窗口，
        // 让用户先看到「将要截下来的原始画面」。
        if let hole = dimHoleRect {
            path.addRect(hole)
        }
        dimLayer.path = path
    }

    private var dimHoleRect: CGRect? {
        if let selection { return selection }
        return hoveredWindowLocalRect
    }

    /// 鼠标下窗口在本显示器内的矩形（已裁进画布），没有则 nil。
    ///
    /// 只在「还没有选区」时用于悬停预览；一旦点选/框选成型就收起高亮，
    /// 选中的窗口不再有蓝色染色（与框选保持一致）。
    private var hoveredWindowLocalRect: CGRect? {
        guard !isSettled, selection == nil, let hoveredWindow else { return nil }
        let rect = DisplayGeometry.localRect(
            fromCGRect: hoveredWindow.frameInCGPoints,
            screen: screen
        )
        let clipped = rect.intersection(canvasBounds)
        return clipped.isEmpty ? nil : clipped
    }

    private func updateSelectionLayers() {
        guard let selection else {
            selectionBorderOuterLayer.isHidden = true
            selectionBorderInnerLayer.isHidden = true
            handlesLayer.path = nil
            sizeLabelLayer.isHidden = true
            return
        }

        selectionBorderOuterLayer.isHidden = false
        selectionBorderInnerLayer.isHidden = true
        // 绿色虚线选框。
        selectionBorderOuterLayer.path = CGPath(rect: selection, transform: nil)

        let path = CGMutablePath()
        let size = Theme.selectionHandleSize
        for handle in SelectionHandle.allCases {
            let center = handle.center(in: selection)
            // 圆形控制点。
            path.addPath(
                CGPath(
                    ellipseIn: CGRect(
                        x: center.x - size / 2,
                        y: center.y - size / 2,
                        width: size,
                        height: size
                    ),
                    transform: nil
                )
            )
        }
        handlesLayer.path = path

        updateSizeLabel(selection)
    }

    private func updateSizeLabel(_ selection: CGRect) {
        let pixelSize = CGSize(
            width: (selection.width * snapshot.effectiveScale).rounded(),
            height: (selection.height * snapshot.effectiveScale).rounded()
        )
        let text = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
        let width = max(96, CGFloat(text.count) * 7.2 + 16)
        let height: CGFloat = 20

        // 优先放在选区内部左上；放不下就移到选区上方外侧。
        var origin = CGPoint(x: selection.minX + 6, y: selection.maxY - height - 6)
        if selection.width < width + 12 {
            origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        }
        origin.x = min(max(origin.x, bounds.minX + 2), bounds.maxX - width - 2)
        origin.y = min(max(origin.y, bounds.minY + 2), bounds.maxY - height - 2)

        sizeLabelLayer.string = text
        sizeLabelLayer.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        sizeLabelLayer.isHidden = false
    }

    private func updateCrosshair() {
        // 选区定型后收起十字线，避免干扰阅读选框内容。
        guard let cursorPoint, !isSettled else {
            crosshairLayer.path = nil
            return
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX, y: cursorPoint.y))
        path.addLine(to: CGPoint(x: bounds.maxX, y: cursorPoint.y))
        path.move(to: CGPoint(x: cursorPoint.x, y: bounds.minY))
        path.addLine(to: CGPoint(x: cursorPoint.x, y: bounds.maxY))
        crosshairLayer.path = path
    }

    private func updateMagnifier() {
        let shouldShow = cursorPoint != nil && !isSettled
        for layer in [
            magnifierLayer, magnifierRingShadowLayer, magnifierRingLayer,
            magnifierCrosshairShadowLayer, magnifierCrosshairLayer, magnifierPillLayer,
            magnifierSwatchLayer, magnifierLabelLayer,
        ] {
            layer.isHidden = !shouldShow
        }
        guard shouldShow, let cursorPoint else { return }

        let size = Theme.magnifierSize
        let pixel = snapshot.pixelPoint(fromLocalPoint: cursorPoint)
        updateMagnifierContents(pixel: pixel, size: size)

        // 跟随光标，贴边时自动翻转。
        var origin = CGPoint(x: cursorPoint.x + 28, y: cursorPoint.y - size / 2)
        if origin.x + size > bounds.maxX {
            origin.x = cursorPoint.x - 28 - size
        }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - size - 8)
        let circleFrame = CGRect(origin: origin, size: CGSize(width: size, height: size))

        magnifierLayer.frame = circleFrame
        magnifierRingShadowLayer.frame = circleFrame
        magnifierRingShadowLayer.path = CGPath(
            ellipseIn: CGRect(origin: .zero, size: circleFrame.size),
            transform: nil
        )
        magnifierRingLayer.frame = circleFrame
        magnifierRingLayer.path = CGPath(
            ellipseIn: CGRect(origin: .zero, size: circleFrame.size),
            transform: nil
        )

        let crosshair = CGMutablePath()
        let arm: CGFloat = 9
        crosshair.move(to: CGPoint(x: size / 2 - arm, y: size / 2))
        crosshair.addLine(to: CGPoint(x: size / 2 + arm, y: size / 2))
        crosshair.move(to: CGPoint(x: size / 2, y: size / 2 - arm))
        crosshair.addLine(to: CGPoint(x: size / 2, y: size / 2 + arm))
        magnifierCrosshairShadowLayer.frame = circleFrame
        magnifierCrosshairShadowLayer.path = crosshair
        magnifierCrosshairLayer.frame = circleFrame
        magnifierCrosshairLayer.path = crosshair

        updateMagnifierReadout(circleFrame: circleFrame, pixel: pixel)
    }

    /// 用 `contentsRect` 做放大：不需要生成中间位图，只是换一个采样窗口。
    private func updateMagnifierContents(pixel: CGPoint, size: CGFloat) {
        let imageWidth = CGFloat(snapshot.image.width)
        let imageHeight = CGFloat(snapshot.image.height)
        let sourcePixels = size / Theme.magnifierZoom * snapshot.effectiveScale
        let unitWidth = min(1, sourcePixels / imageWidth)
        let unitHeight = min(1, sourcePixels / imageHeight)
        magnifierLayer.contentsRect = CGRect(
            x: min(max((pixel.x - sourcePixels / 2) / imageWidth, 0), 1 - unitWidth),
            y: min(max((pixel.y - sourcePixels / 2) / imageHeight, 0), 1 - unitHeight),
            width: unitWidth,
            height: unitHeight
        )
    }

    private func updateMagnifierReadout(circleFrame: CGRect, pixel: CGPoint) {
        // 只在跨过一个像素时才重新取样，天然节流。
        let pixelKey = CGPoint(x: pixel.x.rounded(.down), y: pixel.y.rounded(.down))
        if lastSampledPixel != pixelKey {
            lastSampledPixel = pixelKey
            sampledColor = PixelSampler.sample(snapshot.image, atPixel: pixelKey)
        }

        let text: String
        if let sampledColor {
            text = String(
                format: "%@   %.0f, %.0f",
                sampledColor.hexString,
                pixelKey.x,
                pixelKey.y
            )
            magnifierSwatchLayer.isHidden = false
            magnifierSwatchLayer.backgroundColor = NSColor(
                srgbRed: CGFloat(sampledColor.red) / 255,
                green: CGFloat(sampledColor.green) / 255,
                blue: CGFloat(sampledColor.blue) / 255,
                alpha: 1
            ).cgColor
        } else {
            text = ""
            magnifierSwatchLayer.isHidden = true
        }

        let height: CGFloat = 20
        let swatchSize: CGFloat = 12
        let textWidth = max(60, CGFloat(text.count) * 7.0)
        let pillWidth = 7 + swatchSize + 6 + textWidth + 8
        let pillOrigin = CGPoint(
            x: min(
                max(circleFrame.midX - pillWidth / 2, bounds.minX + 6),
                bounds.maxX - pillWidth - 6
            ),
            y: max(circleFrame.minY - height - 6, bounds.minY + 6)
        )
        let pillFrame = CGRect(
            origin: pillOrigin,
            size: CGSize(width: pillWidth, height: height)
        )

        magnifierPillLayer.frame = pillFrame
        magnifierSwatchLayer.frame = CGRect(
            x: pillFrame.minX + 7,
            y: pillFrame.midY - swatchSize / 2,
            width: swatchSize,
            height: swatchSize
        )
        magnifierLabelLayer.string = text
        magnifierLabelLayer.frame = CGRect(
            x: pillFrame.minX + 7 + swatchSize + 6,
            y: pillFrame.minY,
            width: textWidth + 4,
            height: height
        )
    }

    private func updateWindowHighlight() {
        // 压暗层也要跟着重算（洞口就是被吸附的窗口）。
        updateDimPath()

        guard let window = hoveredWindow, let clipped = hoveredWindowLocalRect else {
            windowHighlightLayer.isHidden = true
            windowLabelLayer.isHidden = true
            return
        }

        windowHighlightLayer.isHidden = false
        windowHighlightLayer.path = CGPath(rect: clipped, transform: nil)

        let text = "\(window.displayName)   \(Int(window.frameInCGPoints.width))×\(Int(window.frameInCGPoints.height))"
        let width = min(bounds.width - 20, max(120, CGFloat(text.count) * 7.2 + 16))
        let height: CGFloat = 20
        let origin = CGPoint(
            x: min(max(clipped.minX, bounds.minX + 6), bounds.maxX - width - 6),
            y: max(clipped.maxY - height - 6, bounds.minY + 6)
        )
        windowLabelLayer.string = text
        windowLabelLayer.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        windowLabelLayer.alignmentMode = .center
        windowLabelLayer.isHidden = false
    }

    private func updateHint() {
        let size = snapshot.pixelSize
        var text = String(
            format: "显示器 %d/%d  ·  %.0f×%.0f px  ·  缩放 %.2fx",
            displayIndex,
            displayCount,
            size.width,
            size.height,
            snapshot.effectiveScale
        )
        text += selection == nil
            ? "  ·  拖拽框选 / 点窗口选整窗  ·  Esc 取消"
            : "  ·  ↵ 完成, ⇥ 上次选区, ⇧ 正方形  ·  Esc 取消"
        let width = min(bounds.width - 40, max(420, CGFloat(text.count) * 7.4))
        hintLayer.string = text
        hintLayer.frame = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.maxY - 56,
            width: width,
            height: 24
        )
    }

    // MARK: - Hit testing

    private var screen: NSScreen {
        NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID }
            ?? NSScreen.screens.first
            ?? NSScreen.main!
    }

    private func updateHoveredWindow(at point: CGPoint) {
        let cgPoint = DisplayGeometry.cgPoint(fromLocal: point, screen: screen)
        let hit = WindowHitTester.frontmost(atCGPoint: cgPoint, in: session.windows)
        #if DEBUG
        if hit?.windowID != hoveredWindow?.windowID {
            print(
                "[canvas \(snapshot.displayID)] hover local=\(Self.describe(point))"
                    + " cg=\(Self.describe(cgPoint))"
                    + " -> \(hit.map { "\($0.ownerName)/\($0.title)" } ?? "nil")"
                    + " of \(session.windows.count) windows"
            )
        }
        #endif
        guard hit?.windowID != hoveredWindow?.windowID else { return }
        hoveredWindow = hit
        updateWindowHighlight()
    }

    #if DEBUG
    private static func describe(_ point: CGPoint) -> String {
        String(format: "(%.0f,%.0f)", point.x, point.y)
    }
    #endif

    private func updateCursor(at point: CGPoint) {
        if let selection, let handle = SelectionGeometry.handle(
            at: point,
            in: selection,
            tolerance: Theme.selectionHandleHitTolerance
        ) {
            SelectionCursor.cursor(for: handle).set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInputArmed else { return }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Events

    override func mouseMoved(with event: NSEvent) {
        guard isInputArmed else { return }
        requestFocusIfNeeded()
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        updateHoveredWindow(at: point)
        updateCrosshair()
        updateMagnifier()
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        hoveredWindow = nil
        updateWindowHighlight()
        updateCrosshair()
        updateMagnifier()
    }

    override func mouseDown(with event: NSEvent) {
        guard isInputArmed else { return }
        if phase == .annotating {
            inlineMouseDown(convert(event.locationInWindow, from: nil))
            return
        }
        requestFocusIfNeeded()
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point

        if let selection {
            if let handle = SelectionGeometry.handle(
                at: point,
                in: selection,
                tolerance: Theme.selectionHandleHitTolerance
            ) {
                interaction = .resizing(handle: handle, original: selection)
                return
            }
            if selection.contains(point) {
                if event.clickCount >= 2 {
                    commit()
                    return
                }
                interaction = .moving(
                    grabOffset: CGSize(
                        width: point.x - selection.minX,
                        height: point.y - selection.minY
                    ),
                    original: selection
                )
                return
            }
            // 在选区外按下：清掉旧选区，开始框新的。
            self.selection = nil
            updateAllLayers()
        }

        interaction = .pressing(anchor: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInputArmed else { return }
        if phase == .annotating {
            inlineMouseDragged(convert(event.locationInWindow, from: nil))
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        let lockAspect = event.modifierFlags.contains(.shift)

        switch interaction {
        case .pressing(let anchor):
            if hypot(point.x - anchor.x, point.y - anchor.y) >= Theme.dragActivationDistance {
                interaction = .selecting(anchor: anchor)
                selection = SelectionGeometry.selectionRect(
                    from: anchor,
                    to: point,
                    clampTo: canvasBounds,
                    square: lockAspect
                )
            }
        case .selecting(let anchor):
            selection = SelectionGeometry.selectionRect(
                from: anchor,
                to: point,
                clampTo: canvasBounds,
                square: lockAspect
            )
        case .resizing(let handle, let original):
            selection = SelectionGeometry.resized(
                original,
                handle: handle,
                to: point,
                clampTo: canvasBounds,
                lockAspect: lockAspect
            )
        case .moving(let grabOffset, let original):
            let delta = CGSize(
                width: point.x - original.minX - grabOffset.width,
                height: point.y - original.minY - grabOffset.height
            )
            selection = SelectionGeometry.moved(original, by: delta, clampTo: canvasBounds)
        case .idle, .settled:
            break
        }

        updateDimPath()
        updateSelectionLayers()
        updateCrosshair()
        updateMagnifier()
        updateHint()
    }

    override func mouseUp(with event: NSEvent) {
        guard isInputArmed else { return }
        if phase == .annotating {
            inlineMouseUp(convert(event.locationInWindow, from: nil))
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point

        switch interaction {
        case .pressing:
            // 单击：命中窗口就**贴边截取**（配合悬停的绿色粗线吸附）。
            if let hoveredWindow {
                selection = DisplayGeometry.localRect(
                    fromCGRect: hoveredWindow.frameInCGPoints,
                    screen: screen
                ).intersection(canvasBounds)
                commit()
                return
            }
            interaction = .idle
        case .selecting:
            if let rect = selection,
                rect.width >= Theme.minimumSelectionSize,
                rect.height >= Theme.minimumSelectionSize
            {
                interaction = .settled
            } else {
                selection = nil
                interaction = .idle
            }
        case .resizing, .moving:
            interaction = .settled
        case .idle, .settled:
            break
        }

        // 就地模式：鼠标一松开（拖拽结束）就弹出标注工具栏。
        if inlineMode, isSettled, phase == .selecting, selection != nil {
            enterAnnotating()
            return
        }

        if isSettled, let selection {
            Self.rememberedSelection[snapshot.displayID] = selection
        }
        updateAllLayers()
        updateHoveredWindow(at: point)
        updateWindowHighlight()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInputArmed else { return }
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        guard isInputArmed else { return }
        if phase == .annotating {
            switch event.keyCode {
            case 53: // Esc：直接退出整个截图
                onCancel?()
            case 36, 76: // Return
                confirmInline()
            case 51, 117: // Delete
                inlineUndo()
            default:
                super.keyDown(with: event)
            }
            return
        }
        switch event.keyCode {
        case 53: // kVK_Escape
            onCancel?()
        case 36, 76: // Return / keypad Enter
            commit()
        case 48: // Tab
            restoreRememberedSelection()
        case 123, 124, 125, 126: // 方向键
            nudge(keyCode: event.keyCode, large: event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Inline annotation

    /// 选区定下来后进入就地标注：工具栏出现在选框下方，直接在冻结画面上标注。
    private func enterAnnotating() {
        guard inlineMode, let selection, selection.width > 1, selection.height > 1 else { return }
        phase = .annotating
        annotations.removeAll()
        redoAnnotations.removeAll()
        annotationDraft = nil
        interaction = .settled
        onInlineEditingChanged?(true)

        selectionBorderOuterLayer.isHidden = true
        selectionBorderInnerLayer.isHidden = true
        handlesLayer.path = nil
        sizeLabelLayer.isHidden = true
        windowHighlightLayer.isHidden = true
        crosshairLayer.path = nil

        preparePreviewBase()
        // 进入时就只弹工具栏，不显示任何标注层，避免画面「跳」一下。
        annotationLayer.contents = nil
        annotationLayer.isHidden = true
        showToolbar()
    }

    private func exitAnnotating() {
        hideToolbar()
        textField?.removeFromSuperview()
        textField = nil
        annotations.removeAll()
        annotationDraft = nil
        annotationLayer.contents = nil
        annotationLayer.isHidden = true
        phase = .selecting
        onInlineEditingChanged?(false)
        updateAllLayers()
    }

    private func cancelInline() {
        exitAnnotating()
        selection = nil
        interaction = .idle
        updateAllLayers()
    }

    private func confirmInline() {
        guard let selection, let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) else {
            cancelInline()
            return
        }
        commitPendingInlineText()
        let final = AnnotationRenderer.render(base: crop, annotations: annotations) ?? crop
        let rect = selection
        exitAnnotating()
        onCommitAnnotated?(final, rect)
    }

    private func preparePreviewBase() {
        guard let selection, let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) else {
            previewBase = nil
            previewScale = 1
            return
        }
        let longest = max(crop.width, crop.height)
        previewScale = longest > 1600 ? 1600 / CGFloat(longest) : 1
        previewBase = Self.rasterize(crop, scale: previewScale)
    }

    private static func rasterize(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func updateAnnotationLayer() {
        toolbarModel?.canUndo = !annotations.isEmpty
        toolbarModel?.canRedo = !redoAnnotations.isEmpty

        // 没有任何标注时不显示标注层（进入就地的那一刻画面保持不变）。
        guard let previewBase, let selection, !(annotations.isEmpty && annotationDraft == nil)
        else {
            annotationLayer.contents = nil
            annotationLayer.isHidden = true
            return
        }
        var list = annotations
        if let annotationDraft { list.append(annotationDraft) }
        let scaled = list.map { $0.scaled(by: previewScale) }
        let image = AnnotationRenderer.render(base: previewBase, annotations: scaled) ?? previewBase
        annotationLayer.frame = selection
        annotationLayer.contents = image
        annotationLayer.isHidden = false
    }

    private func inlineUndo() {
        guard let last = annotations.popLast() else { return }
        redoAnnotations.append(last)
        updateAnnotationLayer()
    }

    private func inlineRedo() {
        guard let restored = redoAnnotations.popLast() else { return }
        annotations.append(restored)
        updateAnnotationLayer()
    }

    // MARK: Inline toolbar

    private func showToolbar() {
        let model = InlineToolbarModel()
        model.onConfirm = { [weak self] in self?.confirmInline() }
        model.onCancel = { [weak self] in self?.onCancel?() }
        model.onUndo = { [weak self] in self?.inlineUndo() }
        model.onRedo = { [weak self] in self?.inlineRedo() }
        toolbarModel = model

        let host = NSHostingView(rootView: InlineAnnotationToolbar(model: model))
        host.translatesAutoresizingMaskIntoConstraints = true
        addSubview(host)
        toolbarHost = host
        updateToolbarPosition()
        observeToolbar(model)
    }

    /// 工具栏展开/收起时自适应宿主视图高度并重新定位。
    private func observeToolbar(_ model: InlineToolbarModel) {
        withObservationTracking {
            _ = model.tool
            _ = model.color
            _ = model.lineWidth
            _ = model.canUndo
            _ = model.canRedo
            _ = model.showColor
            _ = model.showWidth
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if let host = self.toolbarHost {
                    host.setFrameSize(host.fittingSize)
                    self.updateToolbarPosition()
                }
                if self.toolbarModel === model {
                    self.observeToolbar(model)
                }
            }
        }
    }

    private func hideToolbar() {
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
        toolbarModel = nil
    }

    private func updateToolbarPosition() {
        guard let host = toolbarHost, let selection else { return }
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 10 || size.height < 10 {
            size = NSSize(width: 560, height: 56)
        }
        var origin = CGPoint(
            x: selection.midX - size.width / 2,
            y: selection.minY - size.height - 10
        )
        if origin.y < bounds.minY + 8 {
            origin.y = selection.maxY + 10
        }
        origin.x = min(max(origin.x, bounds.minX + 8), max(bounds.minX + 8, bounds.maxX - size.width - 8))
        origin.y = min(origin.y, bounds.maxY - size.height - 8)
        host.frame = CGRect(origin: origin, size: size)
    }

    // MARK: Inline geometry

    /// 视图坐标（原点左下）→ 选区裁剪后的图像像素坐标（原点左上）。
    private func annotationPoint(from point: CGPoint) -> CGPoint {
        guard let selection else { return .zero }
        let scale = snapshot.effectiveScale
        return CGPoint(
            x: (point.x - selection.minX) * scale,
            y: (selection.maxY - point.y) * scale
        )
    }

    private func viewPoint(fromAnnotation point: CGPoint) -> CGPoint {
        guard let selection else { return .zero }
        let scale = snapshot.effectiveScale
        return CGPoint(x: selection.minX + point.x / scale, y: selection.maxY - point.y / scale)
    }

    private func makeInlineDraft(start: CGPoint, current: CGPoint) -> Annotation? {
        guard let model = toolbarModel else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
        switch model.tool {
        case .rectangle: return Annotation(kind: .rectangle(rect), color: model.color, lineWidth: model.lineWidth)
        case .ellipse: return Annotation(kind: .ellipse(rect), color: model.color, lineWidth: model.lineWidth)
        case .highlight: return Annotation(kind: .highlight(rect), color: model.color, lineWidth: model.lineWidth)
        case .pixelate: return Annotation(kind: .pixelate(rect, block: 12), color: model.color, lineWidth: model.lineWidth)
        case .arrow: return Annotation(kind: .arrow(from: start, to: current, control: nil), color: model.color, lineWidth: model.lineWidth)
        case .pen: return Annotation(kind: .pen(points: [start, current]), color: model.color, lineWidth: model.lineWidth)
        case .counter:
            return Annotation(kind: .counter(center: start, value: inlineCounterValue, leader: nil), color: model.color, lineWidth: model.lineWidth)
        case .text: return nil
        case .select: return nil
        }
    }

    private func isValidInlineDraft(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .pixelate(let rect, _):
            return rect.width >= 3 && rect.height >= 3
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 3
        case .counter, .pen, .text:
            return true
        }
    }

    private func inlineMouseDown(_ point: CGPoint) {
        commitPendingInlineText()
        inlineStart = annotationPoint(from: point)
        inlineDragging = true
        annotationDraft = makeInlineDraft(start: inlineStart, current: inlineStart)
        updateAnnotationLayer()
    }

    private func inlineMouseDragged(_ point: CGPoint) {
        guard inlineDragging, let model = toolbarModel else { return }
        let current = annotationPoint(from: point)
        if model.tool == .pen, case .pen(var points) = annotationDraft?.kind {
            points.append(current)
            annotationDraft?.kind = .pen(points: points)
        } else {
            annotationDraft = makeInlineDraft(start: inlineStart, current: current)
        }
        updateAnnotationLayer()
    }

    private func inlineMouseUp(_ point: CGPoint) {
        guard inlineDragging, let model = toolbarModel else { return }
        inlineDragging = false
        let current = annotationPoint(from: point)

        if model.tool == .text {
            annotationDraft = nil
            updateAnnotationLayer()
            beginInlineText(at: inlineStart)
            return
        }
        if let draft = annotationDraft, isValidInlineDraft(draft) {
            annotations.append(draft)
            redoAnnotations.removeAll()
            if case .counter = draft.kind { inlineCounterValue += 1 }
        }
        annotationDraft = nil
        updateAnnotationLayer()
    }

    // MARK: Inline text field

    private var inlineTextOrigin: CGPoint = .zero
    private var inlineCounterValue = 1

    private func beginInlineText(at cropPoint: CGPoint) {
        guard let model = toolbarModel else { return }
        commitPendingInlineText()
        inlineTextOrigin = cropPoint
        let view = viewPoint(fromAnnotation: cropPoint)
        let font = NSFont.systemFont(ofSize: max(12, model.lineWidth * 6))
        let field = NSTextField(
            frame: CGRect(x: view.x, y: view.y - 16, width: 220, height: 30)
        )
        field.font = font
        field.textColor = .white
        field.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        field.drawsBackground = true
        field.isBordered = true
        field.focusRingType = .none
        field.target = self
        field.action = #selector(handleInlineTextCommit)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    @objc private func handleInlineTextCommit() {
        commitPendingInlineText()
    }

    private func commitPendingInlineText() {
        guard let field = textField, let model = toolbarModel else { return }
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = inlineTextOrigin
        field.removeFromSuperview()
        textField = nil
        guard !string.isEmpty else { return }
        annotations.append(
            Annotation(
                kind: .text(origin: origin, string: string, fontSize: max(12, model.lineWidth * 6)),
                color: model.color,
                lineWidth: model.lineWidth
            )
        )
        redoAnnotations.removeAll()
        updateAnnotationLayer()
    }

    // MARK: - Actions

    private func commit() {
        if phase == .annotating {
            confirmInline()
            return
        }
        guard let selection, selection.width >= 1, selection.height >= 1 else { return }
        if inlineMode {
            enterAnnotating()
            return
        }
        Self.rememberedSelection[snapshot.displayID] = selection
        onCommit?(selection)
    }

    private func restoreRememberedSelection() {
        guard let remembered = Self.rememberedSelection[snapshot.displayID] else { return }
        let rect = remembered.intersection(canvasBounds)
        guard !rect.isEmpty else { return }
        selection = rect
        interaction = .settled
        updateAllLayers()
        updateHoveredWindow(at: cursorPoint ?? .zero)
        updateWindowHighlight()
    }

    private func nudge(keyCode: UInt16, large: Bool) {
        guard let selection else { return }
        let step: CGFloat = large ? 10 : 1
        var delta = CGSize.zero
        switch keyCode {
        case 123: delta.width = -step
        case 124: delta.width = step
        case 125: delta.height = -step
        case 126: delta.height = step
        default: return
        }
        self.selection = SelectionGeometry.moved(
            selection,
            by: delta,
            clampTo: canvasBounds
        )
        updateAllLayers()
    }
}
