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
    /// 就地模式：图片在上、工具栏贴在下方，无窗口边框。
    var inline = false
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
    @State private var lineWidth: CGFloat = 8
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

    @State private var editingTextID: UUID?

    /// 内联文字编辑。
    @State private var inlineText = ""
    @State private var inlineOriginView: CGPoint = .zero
    @State private var inlineFontSize: CGFloat = 22
    @FocusState private var inlineFieldFocused: Bool


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

    static let toolbarHeight: CGFloat = 104
    static let padding: CGFloat = 10
    static let minWindowWidth: CGFloat = 900
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
        Group {
            if inline {
                // 就地模式：图片在上，工具栏贴在下方。
                VStack(spacing: 0) {
                    canvasArea
                    toolbar
                }
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    canvasArea
                }
            }
        }
        .background(inline ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: inline ? 320 : Self.minWindowWidth,
            minHeight: inline ? 200 : Self.minWindowHeight
        )
        .onAppear {
            ensurePreviewBase()
            installScrollMonitor()
        }
        .onDisappear { removeScrollMonitor() }
        .onChange(of: bufferScale) { _, _ in ensurePreviewBase() }
        .sheet(isPresented: $isOCRPresented) {
            OCRResultView(text: ocrText) { isOCRPresented = false }
        }
    }

    private var canvasArea: some View {
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
                    zoom = inline ? 1 : min(1, fitFactor(for: newValue))
                }
            }
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
                selectionControls
                textEditorOverlay
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
        .padding(inline ? 0 : Self.padding)
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

    /// 选中框右侧的操作按钮：关闭 / 编辑文字。
    @ViewBuilder
    private var selectionControls: some View {
        if let selected = selectedAnnotation, editingTextID == nil {
            let box = selected.localBounds
            let rightMid = viewPoint(selected.toWorld(CGPoint(x: box.maxX, y: box.midY)))
            VStack(spacing: 6) {
                selectionButton("xmark", "删除") { deleteSelected() }
                if case .text = selected.kind {
                    selectionButton("pencil", "编辑文字") { startTextEditing(id: selected.id) }
                }
            }
            .position(x: rightMid.x + 20, y: rightMid.y)
        }
    }

    private func selectionButton(
        _ symbol: String,
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
                .background(Circle().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// 内联文字编辑：直接在图片原位置输入，不再弹窗。
    @ViewBuilder
    private var textEditorOverlay: some View {
        if editingTextID != nil {
            let font = inlineFontSize * pointsPerPixel
            let measured = Annotation.textSize(
                string: inlineText.isEmpty ? "文字" : inlineText,
                fontSize: inlineFontSize
            )
            let width = max(90, measured.width * pointsPerPixel + 16)
            let height = max(24, font * 1.4 + 8)

            TextField("文字", text: $inlineText)
                .textFieldStyle(.plain)
                .font(.system(size: max(11, font)))
                .foregroundStyle(color.swiftUIColor)
                .padding(.horizontal, 6)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                )
                .position(
                    x: inlineOriginView.x + width / 2,
                    y: inlineOriginView.y + height / 2
                )
                .focused($inlineFieldFocused)
                .onSubmit { commitInlineText() }
                .onExitCommand { cancelInlineText() }
                .onAppear {
                    DispatchQueue.main.async { inlineFieldFocused = true }
                }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(AnnotationTool.allCases) { item in
                    toolButton(item)
                }

                separator

                iconButton("撤销", symbol: "arrow.uturn.backward") { undo() }
                    .disabled(undoStack.isEmpty)
                    .keyboardShortcut("z", modifiers: .command)
                iconButton("重做", symbol: "arrow.uturn.forward") { redo() }
                    .disabled(redoStack.isEmpty)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                iconButton("删除", symbol: "trash") { deleteSelected() }
                    .disabled(selectedID == nil)

                Spacer(minLength: 8)

                zoomControls

                separator

                iconButton("复制", symbol: "doc.on.doc") { exportToCopy() }
                iconButton("保存", symbol: "square.and.arrow.down") { exportToSave() }
                iconButton("OCR", symbol: "text.viewfinder") { exportOCR() }
                    .disabled(isRecognizing)
                iconButton("钉图", symbol: "pin") { exportToPin() }
                iconButton("关闭", symbol: "xmark", tint: .red) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text("\(Int(lineWidth))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 24, alignment: .trailing)
                    Slider(value: $lineWidth, in: 1...24)
                        .frame(width: 150)
                        .tint(.white)
                        .onChange(of: lineWidth) { _, value in
                            applyToSelected { $0.withLineWidth(value) }
                        }
                }

                separator

                HStack(spacing: 10) {
                    ForEach(RGBAColor.palette, id: \.self) { swatch in
                        Button {
                            color = swatch
                            applyToSelected { $0.withColor(swatch) }
                        } label: {
                            Circle()
                                .fill(swatch.swiftUIColor)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().strokeBorder(
                                        color == swatch ? Color.white : Color.white.opacity(0.2),
                                        lineWidth: color == swatch ? 2 : 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                contextualStyleControls

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow)
                Color.black.opacity(0.45)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(
            minWidth: inline ? 0 : Self.minWindowWidth,
            maxWidth: .infinity,
            minHeight: Self.toolbarHeight,
            maxHeight: Self.toolbarHeight
        )
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }

    /// 选中文字 / 马赛克时显示字号 / 块大小。
    @ViewBuilder
    private var contextualStyleControls: some View {
        if let selected = selectedAnnotation {
            switch selected.kind {
            case .text:
                separator
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                    Slider(value: $fontSize, in: 10...100)
                        .frame(width: 90)
                        .tint(.white)
                        .onChange(of: fontSize) { _, value in
                            applyToSelected { $0.withFontSize(value) }
                        }
                }
            case .pixelate:
                separator
                HStack(spacing: 6) {
                    Image(systemName: "squareshape.split.3x3")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                    Slider(value: $mosaicBlock, in: 4...40)
                        .frame(width: 90)
                        .tint(.white)
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
                .font(.system(size: 15, weight: .regular))
                .frame(width: 30, height: 26)
                .foregroundStyle(tool == item ? Theme.selectionGreen : Color.white.opacity(0.9))
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    private func iconButton(
        _ title: String,
        symbol: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
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
                .foregroundStyle(.white.opacity(0.7))
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
        // 开始新的绘制 / 选择前，先落定正在进行的文字编辑。
        if editingTextID != nil {
            commitInlineText()
        }

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
            // 文本：落一个空文本对象，随即进入内联编辑（不弹窗）。
            if let draft, case .text(let origin, _, let size) = draft.kind {
                annotations.append(draft)
                selectedID = draft.id
                editingTextID = draft.id
                inlineText = ""
                inlineFontSize = size
                inlineOriginView = viewPoint(origin)
            }
            self.draft = nil
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

    /// 进入文字内联编辑。
    private func startTextEditing(id: UUID) {
        guard let annotation = annotations.first(where: { $0.id == id }),
            case .text(let origin, let string, let size) = annotation.kind
        else { return }
        selectedID = id
        editingTextID = id
        inlineText = string
        inlineFontSize = size
        inlineOriginView = viewPoint(origin)
    }

    /// 提交内联文字：空文本视为取消并删除该对象。
    private func commitInlineText() {
        guard let id = editingTextID else { return }
        let trimmed = inlineText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            annotations.removeAll { $0.id == id }
        } else if let index = annotations.firstIndex(where: { $0.id == id }) {
            pushUndo()
            annotations[index] = annotations[index].withText(trimmed)
        }
        editingTextID = nil
        inlineText = ""
        inlineFieldFocused = false
    }

    /// 取消内联编辑：新建的空文本对象直接丢弃。
    private func cancelInlineText() {
        if let id = editingTextID {
            annotations.removeAll { $0.id == id }
        }
        editingTextID = nil
        inlineText = ""
        inlineFieldFocused = false
    }

    private func topmostAnnotation(at point: CGPoint) -> Annotation? {
        let tolerance = max(6, pointsPerPixel > 0 ? 8 / pointsPerPixel : 6)
        return annotations.last { $0.contains(point, tolerance: tolerance) }
    }

    /// 双击：文字直接进内联编辑态。
    private func handleDoubleClick(at location: CGPoint) {
        let point = imagePoint(from: location)
        guard let hit = topmostAnnotation(at: point) else { return }
        selectedID = hit.id
        if case .text = hit.kind {
            startTextEditing(id: hit.id)
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
        zoom = inline ? 1 : min(1, fitFactor(for: availableSize))
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
