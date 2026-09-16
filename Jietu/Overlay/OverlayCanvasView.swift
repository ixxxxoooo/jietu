import AppKit
import SwiftUI
import os

/// 遮罩画布：选区状态机 + 全部视觉层。
///
/// 分层设计（性能关键）：整屏冻结图放在**静态**的 `imageLayer` 里永不重绘，
/// 鼠标移动只更新十字线、放大镜、尺寸标签这几个小图层。若把图像画进 `draw(_:)`，
/// 6K 分辨率下每帧都要重新合成整屏，拖动会明显掉帧。
final class OverlayCanvasView: NSView {
    private let logger = Logger(subsystem: "com.ixxxxoooo.jietu", category: "overlay")

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


    /// 上次用过的选区，按显示器记忆，Tab 恢复。
    private static var rememberedSelection: [CGDirectDisplayID: CGRect] = [:]

    /// 遮罩刚出现时，窗口出现在光标之下会送来一次「按住状态」的杂散 mouseDown
    /// （实测 pressedMouseButtons=1）。用一小段静默期挡掉。
    private var inputArmedAt: TimeInterval = 0

    // MARK: - Inline annotation

    /// 原地编辑模式：选区定下来后不立刻截图，而是在选框下方弹出工具栏原地标注。
    var inlineMode = false
    /// 原地标注完成：参数是已经裁好、并烘焙了标注的最终图，以及选区（local）。
    var onCommitAnnotated: ((CGImage, CGRect) -> Void)?
    /// 进入原地标注时通知 Coordinator（用于同步其它显示器的状态）。
    var onInlineEditingChanged: ((Bool) -> Void)?
    /// 原地工具栏的「下载 / 钉图」回调（钉图额外带选区 local rect，用于原地钉）。
    var onSaveImage: ((CGImage) -> Void)?
    var onPinImage: ((CGImage, CGRect) -> Void)?
    /// 标注默认样式：原地工具栏开出来时用它，改完回报给外部记住。
    var annotationDefaults: AnnotationDefaults = .standard
    var onAnnotationDefaultsChange: ((AnnotationDefaults) -> Void)?

    private enum Phase {
        case selecting
        case annotating
    }

    private var phase: Phase = .selecting
    /// 是否正处于原地标注阶段（供 Coordinator 判断 Esc 归属）。
    var isAnnotationPhase: Bool { phase == .annotating }
    private struct EraserStroke {
        var points: [CGPoint]
        var radius: CGFloat
    }

    private struct Snapshot {
        let annotations: [Annotation]
        let strokes: [EraserStroke]
        /// 选区也进快照：标注态里能拖边缘改区域，撤销时必须连选区一起回滚，
        /// 否则标注会按旧原点画在新选区上、整体错位。
        let selection: CGRect?
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var eraserStrokes: [EraserStroke] = []
    private var selectedID: UUID?
    private var erasing = false
    private var lastErasePoint: CGPoint?

    /// 选择工具下的拖拽类型。
    private enum InlineEditDrag {
        case none
        case moving(id: UUID, start: CGPoint, original: Annotation)
        case resizing(id: UUID, handle: ShapeHandle, original: Annotation)
        case rotating(id: UUID, startAngle: CGFloat, original: Annotation)
        case endpoint(id: UUID, handle: ShapeHandle, original: Annotation)
    }

    private var inlineEditDrag: InlineEditDrag = .none
    /// 正在编辑的已有文字对象（nil 表示新建）。
    private var inlineEditingTextID: UUID?
    private let inlineSelectionBorderLayer = CAShapeLayer()
    private let inlineHandlesLayer = CAShapeLayer()
    private var annotations: [Annotation] = []
    private var annotationDraft: Annotation?
    private var previewBase: CGImage?
    private var previewScale: CGFloat = 1
    private var cropImage: CGImage?
    private var liveTextHost: NSView?
    private var toolbarModel: InlineToolbarModel?
    private var mainToolbarHost: NSView?
    private var optionsToolbarHost: NSView?
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

        // 原地标注层：叠在冻结图之上、压暗层之下（选区被挖空，所以标注可见）。
        annotationLayer.frame = bounds
        annotationLayer.contentsGravity = .resize
        annotationLayer.magnificationFilter = .nearest
        annotationLayer.isHidden = true
        // 关闭隐式动画：否则设置 contents/frame 会有 0.25s 过渡，表现为「闪一下」。
        annotationLayer.actions = [
            "contents": NSNull(),
            "frame": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "hidden": NSNull(),
            "opacity": NSNull(),
        ]
        root.addSublayer(annotationLayer)

        // 原地选择态：虚线包围盒 + 控制点。
        inlineSelectionBorderLayer.fillColor = nil
        inlineSelectionBorderLayer.strokeColor = NSColor(Theme.selectionGreen).cgColor
        inlineSelectionBorderLayer.lineWidth = 1.2
        inlineSelectionBorderLayer.lineDashPattern = [5, 3]
        inlineSelectionBorderLayer.isHidden = true
        root.addSublayer(inlineSelectionBorderLayer)

        inlineHandlesLayer.fillColor = NSColor.white.cgColor
        inlineHandlesLayer.strokeColor = NSColor(Theme.selectionGreen).cgColor
        inlineHandlesLayer.lineWidth = 1.2
        inlineHandlesLayer.isHidden = true
        root.addSublayer(inlineHandlesLayer)

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

        // 关闭这些图层的隐式动画：否则隐藏/改 path 时会有淡入淡出或缩放过渡。
        let noActions: [String: CAAction] = [
            "path": NSNull(),
            "hidden": NSNull(),
            "opacity": NSNull(),
            "contents": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull(),
        ]
        for layer in [
            dimLayer, windowHighlightLayer, selectionBorderOuterLayer,
            selectionBorderInnerLayer, handlesLayer, crosshairLayer,
            inlineSelectionBorderLayer, inlineHandlesLayer,
        ] {
            layer.actions = noActions
        }

        crosshairLayer.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        crosshairLayer.lineWidth = 1
        crosshairLayer.fillColor = nil
        crosshairLayer.frame = bounds
        root.addSublayer(crosshairLayer)


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

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? snapshot.nominalScaleFactor
        for layer in [
            imageLayer, dimLayer, windowHighlightLayer, selectionBorderOuterLayer,
            selectionBorderInnerLayer, handlesLayer, crosshairLayer,
            inlineSelectionBorderLayer, inlineHandlesLayer,
        ] {
            layer.frame = bounds
        }
        imageLayer.contentsScale = scale
        // 标注层尺寸由 updateAnnotationLayer() 按选区设置，这里不能重置成整屏。
        annotationLayer.contentsScale = scale
        for textLayer in [sizeLabelLayer, windowLabelLayer, hintLayer] {
            textLayer.contentsScale = scale
        }
        updateAllLayers()
        layoutToolbars()
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
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        hoveredWindow = nil
        updateWindowHighlight()
        updateCrosshair()
    }

    override func mouseDown(with event: NSEvent) {
        guard isInputArmed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            requestFocusIfNeeded()
            cursorPoint = point
            // 选区边缘优先接管：绿框还在，抓着边缘就是继续调区域，框内照旧用来标注。
            if let selection,
                let handle = SelectionGeometry.handle(
                    at: point,
                    in: selection,
                    tolerance: Theme.selectionHandleHitTolerance
                )
            {
                // 整段拖拽算一步撤销。
                pushUndo()
                interaction = .resizing(handle: handle, original: selection)
                return
            }
            inlineMouseDown(point, clickCount: event.clickCount)
            return
        }
        requestFocusIfNeeded()
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
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            // 正在拖选区边缘 → 继续改区域；否则交给原地标注。
            if case .resizing(let handle, let original) = interaction {
                cursorPoint = point
                let updated = SelectionGeometry.resized(
                    original,
                    handle: handle,
                    to: point,
                    clampTo: canvasBounds,
                    lockAspect: event.modifierFlags.contains(.shift)
                )
                // 用「上一次的选区」算增量：每次拖拽事件都只平移一次。
                applyRegionResize(from: selection ?? original, to: updated)
                return
            }
            inlineMouseDragged(point)
            return
        }
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
        updateHint()
    }

    override func mouseUp(with event: NSEvent) {
        guard isInputArmed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            // 拖选区边缘收手：回到「已定」状态，不把它当成一次标注。
            if case .resizing = interaction {
                interaction = .settled
                return
            }
            inlineMouseUp(point)
            return
        }
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

        // 原地模式：鼠标一松开（拖拽结束）就弹出标注工具栏。
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

    /// 选区定下来后进入原地标注：工具栏出现在选框下方，直接在冻结画面上标注。
    private func enterAnnotating() {
        guard inlineMode, let selection, selection.width > 1, selection.height > 1 else { return }
        phase = .annotating
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        eraserStrokes.removeAll()
        annotationDraft = nil
        selectedID = nil
        inlineEditingTextID = nil
        interaction = .settled
        onInlineEditingChanged?(true)

        // 选区绿框与控制点**继续留在画面上**：工具栏弹出后，拖着边缘还能改区域。
        updateSelectionLayers()
        windowHighlightLayer.isHidden = true
        crosshairLayer.path = nil

        preparePreviewBase()
        updateLiveTextOverlay()
        // 进入时就只弹工具栏，不显示任何标注层，避免画面「跳」一下。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        annotationLayer.contents = nil
        annotationLayer.isHidden = true
        CATransaction.commit()
        showToolbar()
    }

    private func exitAnnotating() {
        hideToolbar()
        liveTextHost?.removeFromSuperview()
        liveTextHost = nil
        cropImage = nil
        textField?.removeFromSuperview()
        textField = nil
        annotations.removeAll()
        eraserStrokes.removeAll()
        annotationDraft = nil
        selectedID = nil
        inlineEditingTextID = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        annotationLayer.contents = nil
        annotationLayer.isHidden = true
        inlineSelectionBorderLayer.isHidden = true
        inlineHandlesLayer.isHidden = true
        CATransaction.commit()
        phase = .selecting
        onInlineEditingChanged?(false)
        updateAllLayers()
    }

    /// 标注态里拖动选区边缘：改选区的同时，把标注 / 橡皮笔迹按**新原点**平移，
    /// 让它们继续钉在画面的同一处（否则会跟着框一起跑）。
    private func applyRegionResize(from previous: CGRect, to updated: CGRect) {
        guard updated != previous else { return }

        // 选区原点在屏幕坐标里的位移 → 图像坐标里的反向位移：
        // 左 / 上边缘往外扩，同一画面内容在图像里的坐标就变大。
        let delta = SelectionGeometry.imageDelta(
            from: previous,
            to: updated,
            scale: snapshot.effectiveScale
        )
        if delta != .zero {
            annotations = annotations.map { $0.translated(by: delta) }
            eraserStrokes = eraserStrokes.map { stroke in
                EraserStroke(
                    points: stroke.points.map {
                        CGPoint(x: $0.x + delta.width, y: $0.y + delta.height)
                    },
                    radius: stroke.radius
                )
            }
            if let draft = annotationDraft {
                annotationDraft = draft.translated(by: delta)
            }
        }

        selection = updated
        // 底图换了一块，预览底图 / 标注层 / 选区视觉 / 工具栏位置都要跟着更新。
        preparePreviewBase()
        updateDimPath()
        updateSelectionLayers()
        updateAnnotationLayer()
        updateInlineSelectionLayers()
        layoutToolbars()
    }

    private func cancelInline() {
        exitAnnotating()
        selection = nil
        interaction = .idle
        updateAllLayers()
    }

    /// 当前「已烘焙标注」的成图（用于下载 / 钉图）。
    private func currentAnnotatedImage() -> CGImage? {
        commitPendingInlineText()
        guard let selection, let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) else {
            return nil
        }
        return compose(base: crop, annotations: annotations, strokes: eraserStrokes) ?? crop
    }

    private func confirmInline() {
        guard let selection, let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) else {
            cancelInline()
            return
        }
        commitPendingInlineText()
        let final = compose(base: crop, annotations: annotations, strokes: eraserStrokes) ?? crop
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
        cropImage = crop
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
        toolbarModel?.canUndo = !undoStack.isEmpty
        toolbarModel?.canRedo = !redoStack.isEmpty

        // 草稿要「有实际尺寸」才画；单击产生的零尺寸草稿不显示，避免闪一下。
        var list = annotations
        if let annotationDraft, isMeaningfulDraft(annotationDraft) {
            list.append(annotationDraft)
        }

        let scaledStrokes = eraserStrokes.map {
            EraserStroke(
                points: $0.points.map { CGPoint(x: $0.x * previewScale, y: $0.y * previewScale) },
                radius: $0.radius * previewScale
            )
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard let previewBase, let selection, !list.isEmpty else {
            annotationLayer.contents = nil
            annotationLayer.isHidden = true
            CATransaction.commit()
            return
        }
        let scaled = list.map { $0.scaled(by: previewScale) }
        let image = compose(base: previewBase, annotations: scaled, strokes: scaledStrokes)
            ?? previewBase
        annotationLayer.frame = selection
        annotationLayer.contents = image
        annotationLayer.isHidden = false
        CATransaction.commit()
    }

    /// 依次绘制标注，再用「清空」混合模式沿橡皮笔迹擦出透明区域。
    private func compose(
        base: CGImage,
        annotations: [Annotation],
        strokes: [EraserStroke]
    ) -> CGImage? {
        guard let annotated = AnnotationRenderer.render(base: base, annotations: annotations)
        else { return nil }
        guard !strokes.isEmpty else { return annotated }

        let width = annotated.width
        let height = annotated.height
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
        else { return annotated }
        context.draw(annotated, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.clear)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            context.setLineWidth(max(2, stroke.radius * 2))
            let points = stroke.points.map {
                CGPoint(x: $0.x, y: CGFloat(height) - $0.y)
            }
            guard let first = points.first else { continue }
            context.beginPath()
            context.move(to: first)
            if points.count == 1 {
                context.addLine(to: first)
            } else {
                for point in points.dropFirst() { context.addLine(to: point) }
            }
            context.strokePath()
        }
        return context.makeImage()
    }

    /// 草稿是否已经「成形」（用于避免单击时的零尺寸闪烁）。
    private func isMeaningfulDraft(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .pixelate(let rect, _),
            .blur(let rect, _):
            return rect.width >= 1.5 || rect.height >= 1.5
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 2
        case .line(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= 2
        case .pen(let points):
            return points.count >= 2
        case .counter, .callout:
            return true
        case .text:
            return false
        }
    }

    private func pushUndo() {
        undoStack.append(
            Snapshot(annotations: annotations, strokes: eraserStrokes, selection: selection)
        )
        redoStack.removeAll()
    }

    private func inlineUndo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(
            Snapshot(annotations: annotations, strokes: eraserStrokes, selection: selection)
        )
        apply(previous)
    }

    private func inlineRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(
            Snapshot(annotations: annotations, strokes: eraserStrokes, selection: selection)
        )
        apply(next)
    }

    private func apply(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        eraserStrokes = snapshot.strokes

        let selectionChanged = snapshot.selection != selection
        selection = snapshot.selection
        if selectionChanged {
            preparePreviewBase()
            updateDimPath()
            updateSelectionLayers()
            layoutToolbars()
        }

        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }

    // MARK: Inline selection / editing

    private var selectedAnnotation: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    private func updateAnnotation(_ id: UUID, _ transform: (Annotation) -> Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index] = transform(annotations[index])
    }

    /// 选中态的控制点（crop 像素坐标）。
    private func inlineHandles(for annotation: Annotation) -> [(ShapeHandle, CGPoint)] {
        var handles: [(ShapeHandle, CGPoint)] = []
        if abs(annotation.rotation) < 0.001 {
            switch annotation.kind {
            case .rectangle, .ellipse, .highlight, .pixelate, .pen, .text:
                handles.append(contentsOf: ShapeGeometry.resizeHandles(for: annotation))
            default:
                break
            }
        }
        switch annotation.kind {
        case .arrow(let from, let to, let control):
            handles.append((.arrowStart, from))
            handles.append((.arrowEnd, to))
            handles.append(
                (.arrowControl, control ?? CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2))
            )
        case .counter(let center, _, let leader):
            handles.append(
                (.counterLeader, leader ?? CGPoint(x: center.x + 48, y: center.y - 48))
            )
        default:
            break
        }
        handles.append((.rotate, ShapeGeometry.rotateHandle(for: annotation, distance: 28)))
        return handles
    }

    private func updateInlineSelectionLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard phase == .annotating, let selected = selectedAnnotation else {
            inlineSelectionBorderLayer.isHidden = true
            inlineHandlesLayer.isHidden = true
            inlineSelectionBorderLayer.path = nil
            inlineHandlesLayer.path = nil
            return
        }

        let corners = selected.rotatedCorners().map { viewPoint($0) }
        let border = CGMutablePath()
        border.addLines(between: corners)
        border.closeSubpath()
        inlineSelectionBorderLayer.path = border
        inlineSelectionBorderLayer.isHidden = false

        let path = CGMutablePath()
        let radius = Self.inlineHandleRadius
        for (_, point) in inlineHandles(for: selected) {
            let center = viewPoint(point)
            path.addEllipse(
                in: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        }
        inlineHandlesLayer.path = path
        inlineHandlesLayer.isHidden = false
    }

    private static let inlineHandleRadius: CGFloat = 4.5

    private func inlineHitHandle(_ annotation: Annotation, at cropPoint: CGPoint) -> ShapeHandle? {
        let tolerance = 11 * snapshot.effectiveScale
        var best: (ShapeHandle, CGFloat)?
        for (handle, point) in inlineHandles(for: annotation) {
            let distance = Annotation.distance(cropPoint, point)
            if distance <= tolerance, best == nil || distance < best!.1 {
                best = (handle, distance)
            }
        }
        return best?.0
    }

    private func inlineAnnotation(at cropPoint: CGPoint) -> Annotation? {
        let tolerance = max(6, 8 * snapshot.effectiveScale)
        return annotations.last { $0.contains(cropPoint, tolerance: tolerance) }
    }

    private func textOrigin(of annotation: Annotation) -> CGPoint {
        if case .text(let origin, _, _) = annotation.kind { return origin }
        return annotation.center
    }

    // MARK: Inline toolbar

    private func showToolbar() {
        let seed = annotationDefaults.sanitized
        let model = InlineToolbarModel()
        model.tool = seed.tool == .crop ? .rectangle : seed.tool
        model.color = seed.color
        model.lineWidth = seed.lineWidth
        model.eraserSize = seed.eraserSize
        model.mosaicBlock = seed.mosaicBlock
        model.blurRadius = seed.blurRadius
        model.onConfirm = { [weak self] in self?.confirmInline() }
        model.onCancel = { [weak self] in self?.onCancel?() }
        model.onUndo = { [weak self] in self?.inlineUndo() }
        model.onRedo = { [weak self] in self?.inlineRedo() }
        model.onSave = { [weak self] in
            guard let self, let image = self.currentAnnotatedImage() else { return }
            self.onSaveImage?(image)
        }
        model.onPin = { [weak self] in
            guard let self, let image = self.currentAnnotatedImage() else { return }
            self.onPinImage?(image, self.selection ?? .zero)
        }
        toolbarModel = model

        // 主工具栏：固定尺寸，永不重算 → 展开选项时也不闪烁。
        let main = NSHostingView(rootView: InlineMainToolbar(model: model))
        main.translatesAutoresizingMaskIntoConstraints = true
        addSubview(main)
        mainToolbarHost = main
        layoutToolbars()

        // 只在颜色/粗细开关变化时重建下方选项条。
        observeOptions(model)
        observeDefaults(model)
    }

    /// 工具 / 颜色 / 参数变化时回报，由外部落盘（下次截图沿用）。
    private func observeDefaults(_ model: InlineToolbarModel) {
        withObservationTracking {
            _ = model.tool
            _ = model.color
            _ = model.lineWidth
            _ = model.eraserSize
            _ = model.mosaicBlock
            _ = model.blurRadius
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.toolbarModel === model else { return }
                self.onAnnotationDefaultsChange?(
                    AnnotationDefaults(
                        tool: model.tool,
                        color: model.color,
                        lineWidth: model.lineWidth,
                        fontSize: self.annotationDefaults.fontSize,
                        mosaicBlock: model.mosaicBlock,
                        blurRadius: model.blurRadius,
                        eraserSize: model.eraserSize
                    )
                )
                self.observeDefaults(model)
            }
        }
    }

    private func hideToolbar() {
        mainToolbarHost?.removeFromSuperview()
        mainToolbarHost = nil
        optionsToolbarHost?.removeFromSuperview()
        optionsToolbarHost = nil
        toolbarModel = nil
    }

    /// 颜色 / 粗细开关变化时重建选项条（重新量尺寸，避免改尺寸闪烁）。
    private func observeOptions(_ model: InlineToolbarModel) {
        withObservationTracking {
            _ = model.showColor
            _ = model.showWidth
            _ = model.isLiveTextActive
            // 编辑文字时改颜色 / 粗细，输入框要跟着变（所见即所得）。
            _ = model.color
            _ = model.lineWidth
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if let field = self.textField, self.inlineEditingTextID != nil {
                    self.applyInlineTextStyle(field, model: model)
                    self.fitInlineTextField()
                }
                self.rebuildOptionsToolbar()
                self.updateLiveTextOverlay()
                if self.toolbarModel === model {
                    self.observeOptions(model)
                }
            }
        }
    }

    /// 实况文本：选中「选择」工具时铺一层可拖选复制文字的覆盖层。
    private func updateLiveTextOverlay() {
        let wantsLiveText = (toolbarModel?.isLiveTextActive ?? false) && cropImage != nil && selection != nil
        if wantsLiveText {
            if liveTextHost == nil, let image = cropImage {
                let host = NSHostingView(rootView: LiveTextOverlay(image: image))
                host.translatesAutoresizingMaskIntoConstraints = true
                addSubview(host)
                liveTextHost = host
            }
            if let host = liveTextHost, let selection {
                host.frame = selection
            }
        } else {
            liveTextHost?.removeFromSuperview()
            liveTextHost = nil
        }
    }

    private func rebuildOptionsToolbar() {
        optionsToolbarHost?.removeFromSuperview()
        optionsToolbarHost = nil

        guard let model = toolbarModel, model.showColor || model.showWidth else { return }
        let host = NSHostingView(rootView: InlineOptionsToolbar(model: model))
        host.translatesAutoresizingMaskIntoConstraints = true
        addSubview(host)
        optionsToolbarHost = host
        layoutToolbars()
    }

    private func layoutToolbars() {
        guard let selection, let main = mainToolbarHost else { return }
        main.layoutSubtreeIfNeeded()
        let mainSize = main.fittingSize
        var origin = CGPoint(
            x: selection.midX - mainSize.width / 2,
            y: selection.minY - mainSize.height - 10
        )
        if origin.y < bounds.minY + 8 {
            origin.y = selection.maxY + 10
        }
        origin.x = min(
            max(origin.x, bounds.minX + 8),
            max(bounds.minX + 8, bounds.maxX - mainSize.width - 8)
        )
        origin.y = min(origin.y, bounds.maxY - mainSize.height - 8)
        main.frame = CGRect(origin: origin, size: mainSize)

        guard let options = optionsToolbarHost else { return }
        options.layoutSubtreeIfNeeded()
        let size = options.fittingSize
        // 居中到**刚才点的那个按钮**下方（按钮的 midX 由 SwiftUI 上报）。
        let anchorX = main.frame.minX + (toolbarModel?.optionsAnchorX ?? mainSize.width)
        let x = min(
            max(anchorX - size.width / 2, bounds.minX + 8),
            max(bounds.minX + 8, bounds.maxX - size.width - 8)
        )
        options.frame = CGRect(
            x: x,
            y: main.frame.minY - 8 - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: Eraser (see compose)

    // MARK: Inline geometry    // MARK: Inline geometry

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

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        viewPoint(fromAnnotation: point)
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
        case .pixelate: return Annotation(kind: .pixelate(rect, block: model.mosaicBlock), color: model.color, lineWidth: model.lineWidth)
        case .blur: return Annotation(kind: .blur(rect, radius: model.blurRadius), color: model.color, lineWidth: model.lineWidth)
        case .arrow: return Annotation(kind: .arrow(from: start, to: current, control: nil), color: model.color, lineWidth: model.lineWidth)
        case .line: return Annotation(kind: .line(from: start, to: current), color: model.color, lineWidth: model.lineWidth)
        case .pen: return Annotation(kind: .pen(points: [start, current]), color: model.color, lineWidth: model.lineWidth)
        case .counter:
            return Annotation(
                kind: .counter(center: start, value: inlineCounterValue, leader: nil),
                color: model.color,
                lineWidth: model.lineWidth
            )
        // 裁剪只在标注编辑器窗口里提供，原地编辑不参与。
        case .text, .select, .eraser, .crop: return nil
        }
    }

    private func isValidInlineDraft(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .pixelate(let rect, _),
            .blur(let rect, _):
            return rect.width >= 3 && rect.height >= 3
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 3
        case .line(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= 3
        case .counter, .callout, .pen, .text:
            return true
        }
    }

    /// 统一的原地鼠标处理：先命中已有对象（任意工具下都可编辑），空白处才新建。
    private func inlineMouseDown(_ point: CGPoint, clickCount: Int) {
        // 点别处一律先把正在编辑的文字落地。
        commitPendingInlineText()
        let crop = annotationPoint(from: point)
        let tool = toolbarModel?.tool ?? .rectangle

        // 橡皮：画笔式擦除（擦到的地方露出底层）。
        if tool == .eraser {
            commitPendingInlineText()
            pushUndo()
            erasing = true
            lastErasePoint = crop
            let radius = max(3, (toolbarModel?.eraserSize ?? 28) / 2 * snapshot.effectiveScale)
            eraserStrokes.append(EraserStroke(points: [crop], radius: radius))
            updateAnnotationLayer()
            return
        }

        // 1) 选中对象 + 命中控制点 → 缩放 / 旋转 / 端点
        if let selected = selectedAnnotation,
            let handle = inlineHitHandle(selected, at: crop)
        {
            pushUndo()
            switch handle {
            case .rotate:
                let angle = atan2(crop.y - selected.center.y, crop.x - selected.center.x)
                inlineEditDrag = .rotating(id: selected.id, startAngle: angle, original: selected)
            case .arrowStart, .arrowEnd, .arrowControl, .counterLeader:
                inlineEditDrag = .endpoint(id: selected.id, handle: handle, original: selected)
            default:
                inlineEditDrag = .resizing(id: selected.id, handle: handle, original: selected)
            }
            return
        }

        // 2) 命中已有标注 → 选中并移动（不区分当前工具，和编辑窗口一致）
        if let hit = inlineAnnotation(at: crop) {
            selectedID = hit.id
            if clickCount >= 2, case .text = hit.kind {
                beginInlineText(at: textOrigin(of: hit), editing: hit)
                inlineEditDrag = .none
                updateInlineSelectionLayers()
                return
            }
            pushUndo()
            inlineEditDrag = .moving(id: hit.id, start: crop, original: hit)
            updateInlineSelectionLayers()
            return
        }

        // 3) 空白：清空选中；若当前是绘制工具则开始新标注
        selectedID = nil
        inlineEditDrag = .none
        updateInlineSelectionLayers()
        guard tool.isDrawing else { return }

        commitPendingInlineText()
        inlineStart = crop
        inlineDragging = true
        annotationDraft = makeInlineDraft(start: crop, current: crop)
        updateAnnotationLayer()
    }

    private func inlineMouseDragged(_ point: CGPoint) {
        let crop = annotationPoint(from: point)

        if erasing {
            if var stroke = eraserStrokes.last {
                stroke.points.append(crop)
                eraserStrokes[eraserStrokes.count - 1] = stroke
            }
            lastErasePoint = crop
            updateAnnotationLayer()
            return
        }

        if inlineDragging, let model = toolbarModel {
            if model.tool == .pen, case .pen(var points) = annotationDraft?.kind {
                points.append(crop)
                annotationDraft?.kind = .pen(points: points)
            } else {
                annotationDraft = makeInlineDraft(start: inlineStart, current: crop)
            }
            updateAnnotationLayer()
            return
        }

        switch inlineEditDrag {
        case .none:
            break
        case .moving(let id, let start, let original):
            let delta = CGSize(width: crop.x - start.x, height: crop.y - start.y)
            updateAnnotation(id) { _ in original.translated(by: delta) }
        case .resizing(let id, let handle, let original):
            updateAnnotation(id) { _ in
                original.resized(handle: handle, to: crop, lockAspect: false)
            }
        case .rotating(let id, let startAngle, let original):
            let angle = atan2(crop.y - original.center.y, crop.x - original.center.x)
            updateAnnotation(id) { _ in original.rotated(by: angle - startAngle) }
        case .endpoint(let id, let handle, let original):
            updateAnnotation(id) { _ in original.withEndpoint(handle, to: crop) }
        }
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }

    private func inlineMouseUp(_ point: CGPoint) {
        if erasing {
            erasing = false
            lastErasePoint = nil
            return
        }

        if inlineDragging, let model = toolbarModel {
            inlineDragging = false
            if model.tool == .text {
                annotationDraft = nil
                updateAnnotationLayer()
                beginInlineText(at: inlineStart)
                return
            }
            if let draft = annotationDraft, isValidInlineDraft(draft) {
                pushUndo()
                annotations.append(draft)
                selectedID = draft.id
                if case .counter = draft.kind { inlineCounterValue += 1 }
            }
            annotationDraft = nil
            updateAnnotationLayer()
            updateInlineSelectionLayers()
            return
        }

        if case .none = inlineEditDrag { return }
        inlineEditDrag = .none
        updateInlineSelectionLayers()
    }

    // MARK: Inline text field

    private var inlineTextOrigin: CGPoint = .zero
    private var inlineCounterValue = 1

    /// 就地输入文字：**直接落在点击位置**，按最终的字号与颜色显示（所见即所得），
    /// 不弹任何面板、不铺底色，只有一圈很细的同色边框标出编辑框。
    private func beginInlineText(at cropPoint: CGPoint, editing: Annotation? = nil) {
        guard let model = toolbarModel else { return }
        commitPendingInlineText()
        inlineTextOrigin = cropPoint
        inlineEditingTextID = editing?.id

        let existing: String
        if case .text(_, let string, _)? = editing?.kind {
            existing = string
        } else {
            existing = ""
        }

        let field = NSTextField(frame: .zero)
        field.stringValue = existing
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.alignment = .left
        field.wantsLayer = true
        field.target = self
        field.action = #selector(handleInlineTextCommit)
        applyInlineTextStyle(field, model: model)
        addSubview(field)
        textField = field
        fitInlineTextField()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inlineTextDidChange),
            name: NSControl.textDidChangeNotification,
            object: field
        )
        window?.makeFirstResponder(field)
    }

    /// 写入标注的字号（图像像素）：与提交时用的同一条公式。
    private static func inlineTextFontSize(lineWidth: CGFloat) -> CGFloat {
        max(12, lineWidth * 6)
    }

    /// 字号 / 颜色都跟最终渲染一致（Helvetica + 标注色），这才是「所见即所得」。
    private func applyInlineTextStyle(_ field: NSTextField, model: InlineToolbarModel) {
        let scale = max(1, snapshot.effectiveScale)
        let pointSize = Self.inlineTextFontSize(lineWidth: model.lineWidth) / scale
        field.font = NSFont(name: "Helvetica", size: pointSize)
            ?? NSFont.systemFont(ofSize: pointSize)
        let color = NSColor(cgColor: model.color.cgColor) ?? .labelColor
        field.textColor = color
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 2
        field.layer?.borderColor = color.withAlphaComponent(0.45).cgColor
        field.frame.origin = inlineTextFieldOrigin(pointSize: pointSize)
    }

    /// 编辑框左上角对齐点击位置（AppKit 坐标 y 向上）。
    private func inlineTextFieldOrigin(pointSize: CGFloat) -> CGPoint {
        let view = viewPoint(fromAnnotation: inlineTextOrigin)
        return CGPoint(x: view.x, y: view.y - pointSize * 1.4)
    }

    /// 框贴着文字宽度：不然它会吞掉旁边的点击。
    private func fitInlineTextField() {
        guard let field = textField, let font = field.font else { return }
        let textWidth = (field.stringValue as NSString)
            .size(withAttributes: [.font: font]).width
        field.frame = CGRect(
            x: field.frame.origin.x,
            y: field.frame.origin.y,
            width: max(18, textWidth + 8),
            height: font.pointSize * 1.4
        )
    }

    @objc private func inlineTextDidChange() {
        fitInlineTextField()
    }

    @objc private func handleInlineTextCommit() {
        commitPendingInlineText()
    }

    private func commitPendingInlineText() {
        guard let field = textField, let model = toolbarModel else { return }
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = inlineTextOrigin
        let editingID = inlineEditingTextID
        NotificationCenter.default.removeObserver(
            self, name: NSControl.textDidChangeNotification, object: field
        )
        field.removeFromSuperview()
        textField = nil
        inlineEditingTextID = nil

        guard !string.isEmpty else {
            if let editingID {
                pushUndo()
                annotations.removeAll { $0.id == editingID }
            }
            updateAnnotationLayer()
            updateInlineSelectionLayers()
            return
        }

        pushUndo()
        if let editingID, let index = annotations.firstIndex(where: { $0.id == editingID }) {
            annotations[index] = annotations[index].withText(string)
        } else {
            annotations.append(
                Annotation(
                    kind: .text(
                        origin: origin,
                        string: string,
                        fontSize: max(12, model.lineWidth * 6)
                    ),
                    color: model.color,
                    lineWidth: model.lineWidth
                )
            )
        }
        updateAnnotationLayer()
        updateInlineSelectionLayers()
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
