import AppKit
import SwiftUI

/// 标注编辑器主界面。
///
/// 预览：把原图栅格化到与显示像素匹配的底图，再用**同一个渲染器**
/// （`AnnotationRenderer`）把标注烘焙上去显示，保证所见即所得。
///
/// 标注是**对象化**的：选择工具下可点选、整体拖动、用控制点缩放 / 旋转、
/// 拖箭头端点与曲线手柄、拖序号引线；文字双击改文案；颜色 / 线宽 / 字号 /
/// 马赛克块大小都能事后修改。撤销 / 重做基于整份文档快照。
///
/// @author ixxxxoooo
struct AnnotationEditorView: View {
    let baseImage: CGImage
    var onCopy: (CGImage) -> Void
    var onSave: (CGImage) -> Void
    /// 参数二为画布在窗口中的全局坐标（供「原地钉图」定位）。
    var onPin: (CGImage, CGRect) -> Void
    var onClose: () -> Void

    @Environment(\.displayScale) private var displayScale

    // MARK: - Document

    @State private var annotations: [Annotation] = []
    @State private var undoStack: [[Annotation]] = []
    @State private var redoStack: [[Annotation]] = []
    @State private var selectedID: UUID?

    // MARK: - Tool / style

    @State private var tool: AnnotationTool = .rectangle
    @State private var color: RGBAColor = .red
    @State private var lineWidth: CGFloat = 3
    @State private var fontSize: CGFloat = 22
    @State private var mosaicBlock: CGFloat = 10
    @State private var counterValue = 1

    // MARK: - Interaction

    private enum DragMode {
        case none
        case creating(start: CGPoint)
        case moving(id: UUID, start: CGPoint, original: Annotation)
        case resizing(id: UUID, handle: ShapeHandle, original: Annotation)
        case rotating(id: UUID, startAngle: CGFloat, original: Annotation)
        case endpoint(id: UUID, handle: ShapeHandle, original: Annotation)
    }

    @State private var dragMode: DragMode = .none
    @State private var draft: Annotation?

    @State private var isTextPromptPresented = false
    @State private var textInput = ""
    @State private var editingTextID: UUID?

    @State private var ocrText = ""
    @State private var isOCRPresented = false
    @State private var isRecognizing = false

    // MARK: - Preview / zoom

    @State private var previewBase: CGImage?
    @State private var previewBaseScale: CGFloat = -1
    @State private var availableSize: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var hasUserZoomed = false
    @State private var hasInitialized = false
    @State private var canvasGlobalFrame: CGRect = .zero
    @State private var scrollMonitor: Any?

    // MARK: - Layout

    static let toolbarHeight: CGFloat = 58
    static let padding: CGFloat = 10
    static let minWindowWidth: CGFloat = 1240
    static let minWindowHeight: CGFloat = 430
    private static let minZoom: CGFloat = 0.1
    private static let maxZoom: CGFloat = 8
    private static let handleRadius: CGFloat = 4.5
    private static let handleHitRadius: CGFloat = 11

    private var naturalSize: CGSize {
        let scale = max(1, displayScale)
        return CGSize(
            width: CGFloat(baseImage.width) / scale,
            height: CGFloat(baseImage.height) / scale
        )
    }

    private var displayedSize: CGSize {
        CGSize(width: naturalSize.width * zoom, height: naturalSize.height * zoom)
    }

    private var pointsPerPixel: CGFloat { zoom / max(1, displayScale) }

    private var bufferScale: CGFloat { min(zoom, 1) }

    private var selectedAnnotation: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    canvas
                        .frame(width: displayedSize.width, height: displayedSize.height)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
                .onAppear {
                    availableSize = geo.size
                    initializeZoomIfNeeded()
                }
                .onChange(of: geo.size) { _, newValue in
                    availableSize = newValue
                    if !hasUserZoomed {
                        zoom = min(1, fitFactor(for: newValue))
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: Self.minWindowWidth, minHeight: Self.minWindowHeight)
        .onAppear {
            ensurePreviewBase()
            installScrollMonitor()
        }
        .onDisappear { removeScrollMonitor() }
        .onChange(of: bufferScale) { _, _ in ensurePreviewBase() }
        .alert("输入文字", isPresented: $isTextPromptPresented) {
            TextField("文字", text: $textInput)
            Button("确定") { commitText() }
            Button("取消", role: .cancel) { editingTextID = nil }
        }
        .sheet(isPresented: $isOCRPresented) {
            OCRResultView(text: ocrText) { isOCRPresented = false }
        }
    }

    private var canvas: some View {
        ZStack {
            if let rendered = renderedPreview {
                Image(decorative: rendered, scale: 1)
                    .resizable()
                    .interpolation(zoom >= 1 ? .none : .high)
                    .frame(width: displayedSize.width, height: displayedSize.height)
                    .contentShape(Rectangle())
                    .gesture(drawGesture)
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2).onEnded { value in
                            handleDoubleClick(at: value.location)
                        }
                    )
                    .overlay(
                        Rectangle()
                            .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
                selectionOverlay
            } else {
                ProgressView()
                    .frame(width: 240, height: 160)
            }
        }
        .frame(width: displayedSize.width, height: displayedSize.height)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { canvasGlobalFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        canvasGlobalFrame = frame
                    }
            }
        )
        .padding(Self.padding)
    }

    /// 选中态：包围盒 + 控制点。
    private var selectionOverlay: some View {
        Canvas { context, _ in
            guard let selected = selectedAnnotation else { return }

            let corners = selected.rotatedCorners().map(viewPoint)
            var border = Path()
            border.addLines(corners)
            border.closeSubpath()
            context.stroke(
                border,
                with: .color(Color.accentColor),
                style: StrokeStyle(lineWidth: 1.2, dash: [5, 3])
            )

            for (handle, position) in shapHandles(for: selected) {
                let center = viewPoint(position)
                let rect = CGRect(
                    x: center.x - Self.handleRadius,
                    y: center.y - Self.handleRadius,
                    width: Self.handleRadius * 2,
                    height: Self.handleRadius * 2
                )
                let isRotate = handle == .rotate
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(isRotate ? Color.accentColor : .white)
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(Color.accentColor),
                    lineWidth: 1.2
                )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(AnnotationTool.allCases) { item in
                toolButton(item)
            }

            Divider().frame(height: 20)

            ForEach(RGBAColor.palette, id: \.self) { swatch in
                colorButton(swatch)
            }

            Divider().frame(height: 20)

            HStack(spacing: 6) {
                Image(systemName: "lineweight")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: $lineWidth, in: 1...16)
                    .frame(width: 64)
                    .onChange(of: lineWidth) { _, value in
                        applyToSelected { $0.withLineWidth(value) }
                    }
            }

            contextualStyleControls

            Spacer(minLength: 8)

            zoomControls

            Divider().frame(height: 20)

            iconButton("撤销", symbol: "arrow.uturn.backward") { undo() }
                .disabled(undoStack.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
            iconButton("重做", symbol: "arrow.uturn.forward") { redo() }
                .disabled(redoStack.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            iconButton("删除", symbol: "trash") { deleteSelected() }
                .disabled(selectedID == nil)

            Divider().frame(height: 20)

            iconButton("复制", symbol: "doc.on.doc") { exportToCopy() }
            iconButton("保存", symbol: "square.and.arrow.down") { exportToSave() }
            iconButton("OCR", symbol: "text.viewfinder") { exportOCR() }
                .disabled(isRecognizing)
            iconButton("钉图", symbol: "pin") { exportToPin() }
            iconButton("关闭", symbol: "xmark") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(
            minWidth: Self.minWindowWidth,
            maxWidth: .infinity,
            minHeight: Self.toolbarHeight,
            maxHeight: Self.toolbarHeight
        )
    }

    /// 选中文字 / 马赛克时显示字号 / 块大小。
    @ViewBuilder
    private var contextualStyleControls: some View {
        if let selected = selectedAnnotation {
            switch selected.kind {
            case .text:
                Divider().frame(height: 20)
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(value: $fontSize, in: 10...100)
                        .frame(width: 80)
                        .onChange(of: fontSize) { _, value in
                            applyToSelected { $0.withFontSize(value) }
                        }
                }
            case .pixelate:
                Divider().frame(height: 20)
                HStack(spacing: 6) {
                    Image(systemName: "squareshape.split.3x3")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(value: $mosaicBlock, in: 4...40)
                        .frame(width: 80)
                        .onChange(of: mosaicBlock) { _, value in
                            applyToSelected { $0.withPixelateBlock(value) }
                        }
                }
            default:
                EmptyView()
            }
        }
    }

    private func toolButton(_ item: AnnotationTool) -> some View {
        Button {
            tool = item
            if item.isDrawing { selectedID = nil }
        } label: {
            Image(systemName: item.symbolName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tool == item ? Theme.brand : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    private func colorButton(_ swatch: RGBAColor) -> some View {
        Button {
            color = swatch
            applyToSelected { $0.withColor(swatch) }
        } label: {
            Circle()
                .fill(swatch.swiftUIColor)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().strokeBorder(
                        color == swatch ? Theme.brand : Color.primary.opacity(0.25),
                        lineWidth: color == swatch ? 2 : 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func iconButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .foregroundStyle(.white)
        }
        .buttonStyle(.borderless)
        .help(title)
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button("适应") { zoomToFit() }
                .buttonStyle(.link)
                .font(.system(size: 11))
            iconButton("缩小", symbol: "minus.magnifyingglass") { zoomOut() }
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42)
            iconButton("放大", symbol: "plus.magnifyingglass") { zoomIn() }
            Button("原始") { zoomToOriginal() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
    }

    // MARK: - Gesture

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startPx = imagePoint(from: value.startLocation)
                let currentPx = imagePoint(from: value.location)
                let startView = value.startLocation
                let currentView = value.location

                if case .none = dragMode {
                    beginDrag(startPx: startPx, startView: startView)
                }
                continueDrag(currentPx: currentPx, currentView: currentView)
            }
            .onEnded { value in
                let currentPx = imagePoint(from: value.location)
                endDrag(currentPx: currentPx)
            }
    }

    private func beginDrag(startPx: CGPoint, startView: CGPoint) {
        // 1) 选中标注的控制点
        if let selected = selectedAnnotation,
            let handle = hitHandle(for: selected, at: startView)
        {
            pushUndo()
            switch handle {
            case .rotate:
                let angle = atan2(startPx.y - selected.center.y, startPx.x - selected.center.x)
                dragMode = .rotating(id: selected.id, startAngle: angle, original: selected)
            case .arrowStart, .arrowEnd, .arrowControl, .counterLeader:
                dragMode = .endpoint(id: selected.id, handle: handle, original: selected)
            default:
                dragMode = .resizing(id: selected.id, handle: handle, original: selected)
            }
            return
        }

        // 2) 命中已有标注 → 选中并移动
        if let hit = topmostAnnotation(at: startPx) {
            selectedID = hit.id
            color = hit.color
            lineWidth = hit.lineWidth
            pushUndo()
            dragMode = .moving(id: hit.id, start: startPx, original: hit)
            return
        }

        // 3) 空白处
        if tool.isDrawing {
            dragMode = .creating(start: startPx)
        } else {
            selectedID = nil
            dragMode = .none
        }
    }

    private func continueDrag(currentPx: CGPoint, currentView: CGPoint) {
        switch dragMode {
        case .none:
            break
        case .creating(let start):
            draft = makeDraft(tool: tool, start: start, current: currentPx)
        case .moving(let id, let start, let original):
            let delta = CGSize(width: currentPx.x - start.x, height: currentPx.y - start.y)
            update(id: id) { _ in original.translated(by: delta) }
        case .resizing(let id, let handle, let original):
            update(id: id) { _ in original.resized(handle: handle, to: currentPx, lockAspect: false) }
        case .rotating(let id, let startAngle, let original):
            let angle = atan2(currentPx.y - original.center.y, currentPx.x - original.center.x)
            update(id: id) { _ in original.rotated(by: angle - startAngle) }
        case .endpoint(let id, let handle, let original):
            update(id: id) { _ in original.withEndpoint(handle, to: currentPx) }
        }
    }

    private func endDrag(currentPx: CGPoint) {
        if case .creating = dragMode, tool == .text {
            // 文本：先弹输入框，确定时再用 draft 落盘。
            if draft != nil {
                editingTextID = nil
                textInput = ""
                isTextPromptPresented = true
            }
            dragMode = .none
            return
        }

        switch dragMode {
        case .creating:
            if let draft, isValid(draft) {
                pushUndo()
                annotations.append(draft)
                selectedID = draft.id
                if case .counter = draft.kind { counterValue += 1 }
            }
        default:
            break
        }
        draft = nil
        dragMode = .none
    }

    private func makeDraft(tool: AnnotationTool, start: CGPoint, current: CGPoint) -> Annotation? {
        let rect = normalizedRect(start, current)
        switch tool {
        case .rectangle:
            return Annotation(kind: .rectangle(rect), color: color, lineWidth: lineWidth)
        case .ellipse:
            return Annotation(kind: .ellipse(rect), color: color, lineWidth: lineWidth)
        case .highlight:
            return Annotation(kind: .highlight(rect), color: color, lineWidth: lineWidth)
        case .pixelate:
            return Annotation(kind: .pixelate(rect, block: mosaicBlock), color: color, lineWidth: lineWidth)
        case .arrow:
            return Annotation(kind: .arrow(from: start, to: current, control: nil), color: color, lineWidth: lineWidth)
        case .pen:
            return Annotation(kind: .pen(points: [start, current]), color: color, lineWidth: lineWidth)
        case .counter:
            return Annotation(kind: .counter(center: current, value: counterValue, leader: nil), color: color, lineWidth: lineWidth)
        case .text:
            return Annotation(
                kind: .text(origin: start, string: "", fontSize: fontSize),
                color: color,
                lineWidth: lineWidth
            )
        case .select:
            return nil
        }
    }

    // MARK: - Editing ops

    private func pushUndo() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    private func update(id: UUID, _ transform: (Annotation) -> Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index] = transform(annotations[index])
    }

    private func applyToSelected(_ transform: (Annotation) -> Annotation) {
        guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID })
        else { return }
        annotations[index] = transform(annotations[index])
    }

    private func deleteSelected() {
        guard let selectedID else { return }
        pushUndo()
        annotations.removeAll { $0.id == selectedID }
        self.selectedID = nil
    }

    private func commitText() {
        let trimmed = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { textInput = ""; editingTextID = nil }
        guard !trimmed.isEmpty else { return }

        if let editingTextID, let index = annotations.firstIndex(where: { $0.id == editingTextID }) {
            pushUndo()
            annotations[index] = annotations[index].withText(trimmed)
            self.editingTextID = nil
            return
        }
        guard let draft else { return }
        pushUndo()
        let text = draft.withText(trimmed)
        annotations.append(text)
        selectedID = text.id
        self.draft = nil
    }

    private func topmostAnnotation(at point: CGPoint) -> Annotation? {
        let tolerance = max(6, pointsPerPixel > 0 ? 8 / pointsPerPixel : 6)
        return annotations.last { $0.contains(point, tolerance: tolerance) }
    }

    /// 双击：文字直接进编辑态。
    private func handleDoubleClick(at location: CGPoint) {
        let point = imagePoint(from: location)
        guard let hit = topmostAnnotation(at: point) else { return }
        selectedID = hit.id
        if case .text(_, let string, _) = hit.kind {
            editingTextID = hit.id
            textInput = string
            isTextPromptPresented = true
        }
    }

    private func hitHandle(for annotation: Annotation, at viewPoint: CGPoint) -> ShapeHandle? {
        var best: (ShapeHandle, CGFloat)?
        for (handle, position) in shapHandles(for: annotation) {
            let distance = Annotation.distance(viewPoint, self.viewPoint(position))
            if distance <= Self.handleHitRadius, best == nil || distance < best!.1 {
                best = (handle, distance)
            }
        }
        return best?.0
    }

    /// 选中标注的控制点（图像坐标）。旋转后仅提供旋转手柄 + 该类型的端点手柄。
    private func shapHandles(for annotation: Annotation) -> [(ShapeHandle, CGPoint)] {
        var handles: [(ShapeHandle, CGPoint)] = []
        let rotated = abs(annotation.rotation) > 0.001

        if !rotated {
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
            let mid = control ?? CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            handles.append((.arrowControl, mid))
        case .counter(let center, _, let leader):
            let leaderPoint = leader ?? CGPoint(x: center.x + 48, y: center.y - 48)
            handles.append((.counterLeader, leaderPoint))
        default:
            break
        }

        handles.append((.rotate, ShapeGeometry.rotateHandle(for: annotation, distance: 28)))
        return handles
    }

    // MARK: - Zoom

    private func fitFactor(for available: CGSize) -> CGFloat {
        guard available.width > 1, available.height > 1 else { return 1 }
        let natural = naturalSize
        guard natural.width > 0, natural.height > 0 else { return 1 }
        let padded = CGSize(
            width: max(1, available.width - Self.padding * 2),
            height: max(1, available.height - Self.padding * 2)
        )
        return min(padded.width / natural.width, padded.height / natural.height)
    }

    private func initializeZoomIfNeeded() {
        guard !hasInitialized else { return }
        hasInitialized = true
        zoom = min(1, fitFactor(for: availableSize))
    }

    private func zoomIn() {
        hasUserZoomed = true
        zoom = min(Self.maxZoom, zoom * 1.25)
    }

    private func zoomOut() {
        hasUserZoomed = true
        zoom = max(Self.minZoom, zoom / 1.25)
    }

    private func zoomToFit() {
        hasUserZoomed = false
        zoom = min(1, fitFactor(for: availableSize))
    }

    private func zoomToOriginal() {
        hasUserZoomed = true
        zoom = 1
    }

    /// 监听本窗口的滚轮 / 捏合手势做缩放（SwiftUI 没有直接的滚轮事件接口）。
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard event.window?.title == "标注" else { return event }
            if event.type == .magnify {
                applyZoomFactor(1 + event.magnification)
            } else {
                let raw = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY / 8
                    : event.scrollingDeltaY
                guard raw != 0 else { return event }
                applyZoomFactor(min(1.5, max(0.67, 1 + raw * 0.05)))
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
    }

    private func applyZoomFactor(_ factor: CGFloat) {
        hasUserZoomed = true
        zoom = min(Self.maxZoom, max(Self.minZoom, zoom * factor))
    }

    // MARK: - Export

    private func renderedImage() -> CGImage? {
        AnnotationRenderer.render(base: baseImage, annotations: annotations)
    }

    private func exportToCopy() {
        guard let rendered = renderedImage() else { return }
        onCopy(rendered)
    }

    private func exportToSave() {
        guard let rendered = renderedImage() else { return }
        onSave(rendered)
    }

    private func exportToPin() {
        guard let rendered = renderedImage() else { return }
        onPin(rendered, canvasGlobalFrame)
    }

    private func exportOCR() {
        guard let rendered = renderedImage(), !isRecognizing else { return }
        isRecognizing = true
        Task { @MainActor in
            let text = await OCRService.recognizeText(in: rendered)
            isRecognizing = false
            ocrText = text
            if !text.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            isOCRPresented = true
        }
    }

    // MARK: - Preview rendering

    private var renderedPreview: CGImage? {
        guard let previewBase else { return nil }
        var list = annotations
        if let draft { list.append(draft) }
        let scale = previewBaseScale
        let scaled = list.map { $0.scaled(by: scale) }
        return AnnotationRenderer.render(base: previewBase, annotations: scaled)
    }

    private func ensurePreviewBase() {
        let scale = bufferScale
        guard previewBase == nil || abs(previewBaseScale - scale) > 0.0001 else { return }
        previewBase = Self.rasterize(baseImage, scale: scale)
        previewBaseScale = scale
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

    // MARK: - Geometry helpers

    private func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        guard pointsPerPixel > 0 else { return .zero }
        return CGPoint(x: viewPoint.x / pointsPerPixel, y: viewPoint.y / pointsPerPixel)
    }

    private func viewPoint(_ imagePoint: CGPoint) -> CGPoint {
        CGPoint(x: imagePoint.x * pointsPerPixel, y: imagePoint.y * pointsPerPixel)
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private func isValid(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .pixelate(let rect, _):
            return rect.width >= 4 && rect.height >= 4
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 4
        case .pen(let points):
            return points.count >= 2
        case .text, .counter:
            return true
        }
    }

    // MARK: - Window sizing

    static func initialWindowSize(for image: CGImage, screen: NSScreen?) -> CGSize {
        let scale = max(1, screen?.backingScaleFactor ?? 2)
        let natural = CGSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxCanvas = CGSize(
            width: max(minWindowWidth, visible.width * 0.9),
            height: visible.height * 0.9 - toolbarHeight
        )
        let fit = min(
            1,
            min(maxCanvas.width / max(1, natural.width), maxCanvas.height / max(1, natural.height))
        )
        return CGSize(
            width: max(minWindowWidth, natural.width * fit),
            height: max(minWindowHeight, natural.height * fit + toolbarHeight)
        )
    }
}

extension RGBAColor {
    /// UI 层的 SwiftUI 颜色桥接。
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// OCR 结果弹窗：只读文本 + 复制 / 关闭。
///
/// @author ixxxxoooo
struct OCRResultView: View {
    let text: String
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("文字识别结果", systemImage: "text.viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            if text.isEmpty {
                Text("没有识别到文字")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: .constant(text))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 460, minHeight: 260)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
            HStack {
                Text("已复制到剪贴板")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }
                .disabled(text.isEmpty)
                Button("关闭") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 380)
    }
}
