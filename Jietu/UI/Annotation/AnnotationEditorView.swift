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
    /// 初始样式（沿用上次用的工具 / 颜色 / 参数）。
    var defaults: AnnotationDefaults = .standard
    /// 样式变化时回报，由外部落盘记住。
    var onDefaultsChange: ((AnnotationDefaults) -> Void)?
    var onCopy: (CGImage) -> Void
    var onSave: (CGImage) -> Void
    /// 参数二为画布在窗口中的全局坐标（供「原地钉图」定位）。
    var onPin: (CGImage, CGRect) -> Void
    var onClose: () -> Void

    init(
        baseImage: CGImage,
        inline: Bool = false,
        defaults: AnnotationDefaults = .standard,
        onDefaultsChange: ((AnnotationDefaults) -> Void)? = nil,
        onCopy: @escaping (CGImage) -> Void,
        onSave: @escaping (CGImage) -> Void,
        onPin: @escaping (CGImage, CGRect) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.baseImage = baseImage
        self.inline = inline
        self.defaults = defaults
        self.onDefaultsChange = onDefaultsChange
        self.onCopy = onCopy
        self.onSave = onSave
        self.onPin = onPin
        self.onClose = onClose

        let defaults = defaults.sanitized
        _tool = State(initialValue: defaults.tool)
        _color = State(initialValue: defaults.color)
        _lineWidth = State(initialValue: defaults.lineWidth)
        _fontSize = State(initialValue: defaults.fontSize)
        _mosaicBlock = State(initialValue: defaults.mosaicBlock)
        _blurRadius = State(initialValue: defaults.blurRadius)
        _magnifierZoom = State(initialValue: defaults.magnifierZoom)
        _eraserSize = State(initialValue: defaults.eraserSize)
    }

    @Environment(\.displayScale) private var displayScale

    // MARK: - Document

    @State private var annotations: [Annotation] = []
    @State private var eraserStrokes: [EraserStroke] = []
    @State private var undoStack: [EditorSnapshot] = []
    @State private var redoStack: [EditorSnapshot] = []
    @State private var selectedID: UUID?
    /// 「复制样式」暂存的样式，供「粘贴样式」用。
    @State private var styleClipboard: AnnotationStyle?
    @State private var eraserSize: CGFloat = 28

    /// 裁剪后的底图；nil 表示还没裁过，用原始截图。
    @State private var croppedImage: CGImage?
    /// 确认裁剪前待应用的选区（图像像素坐标）。
    @State private var cropRect: CGRect?

    /// 当前实际使用的底图（裁剪会换掉它）。
    private var currentBase: CGImage { croppedImage ?? baseImage }

    struct EditorSnapshot {
        let annotations: [Annotation]
        let strokes: [EraserStroke]
        /// 裁剪会换底图，撤销必须一起回滚。
        let croppedImage: CGImage?
    }

    // MARK: - Tool / style

    @State private var tool: AnnotationTool = .rectangle
    @State private var color: RGBAColor = .red
    @State private var lineWidth: CGFloat = 7
    @State private var fontSize: CGFloat = 22
    @State private var mosaicBlock: CGFloat = 10
    @State private var blurRadius: CGFloat = 12
    @State private var magnifierZoom: CGFloat = 2
    @State private var counterValue = 1

    // MARK: - Interaction

    private enum DragMode {
        case none
        case creating(start: CGPoint)
        case moving(id: UUID, start: CGPoint, original: Annotation)
        case resizing(id: UUID, handle: ShapeHandle, original: Annotation)
        case rotating(id: UUID, startAngle: CGFloat, original: Annotation)
        case endpoint(id: UUID, handle: ShapeHandle, original: Annotation)
        case erasing
    }

    @State private var dragMode: DragMode = .none
    @State private var draft: Annotation?
    @State private var lastErasePoint: CGPoint?

    @State private var editingTextID: UUID?

    /// 内联文字编辑。
    @State private var inlineText = ""
    @State private var inlineOriginView: CGPoint = .zero
    @State private var inlineFontSize: CGFloat = 22
    @FocusState private var inlineFieldFocused: Bool


    @State private var ocrText = ""
    @State private var isOCRPresented = false
    @State private var isRecognizing = false
    /// 是否开启实况文本（由工具栏 OCR 按钮触发）。
    @State private var isLiveTextActive = false
    @State private var showColor = false
    @State private var showWidth = false

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

    static let toolbarHeight: CGFloat = 56
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
            width: CGFloat(currentBase.width) / scale,
            height: CGFloat(currentBase.height) / scale
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
        .onChange(of: currentDefaults) { _, newValue in
            onDefaultsChange?(newValue)
        }
    }

    /// 当前样式的快照，用于回写「记住上次用的样式」。
    private var currentDefaults: AnnotationDefaults {
        AnnotationDefaults(
            tool: tool,
            color: color,
            lineWidth: lineWidth,
            fontSize: fontSize,
            mosaicBlock: mosaicBlock,
            blurRadius: blurRadius,
            magnifierZoom: magnifierZoom,
            eraserSize: eraserSize
        )
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
                if isLiveTextActive {
                    LiveTextOverlay(image: currentBase)
                        .frame(width: displayedSize.width, height: displayedSize.height)
                }
                selectionOverlay
                selectionControls
                cropOverlay
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

    /// 选中框右侧的操作按钮：层级 / 复制 / 样式 / 删除。
    @ViewBuilder
    private var selectionControls: some View {
        if let selected = selectedAnnotation, editingTextID == nil {
            let box = selected.localBounds
            let rightMid = viewPoint(selected.toWorld(CGPoint(x: box.maxX, y: box.midY)))
            VStack(spacing: 6) {
                selectionButton("arrow.up.to.line", "置顶 ⇧⌘]") { bringSelectedToFront() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                selectionButton("arrow.down.to.line", "置底 ⇧⌘[") { sendSelectedToBack() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                selectionButton("plus.square.on.square", "复制一份 ⌘D") { duplicateSelected() }
                    .keyboardShortcut("d", modifiers: .command)
                selectionButton("paintbrush", "复制样式 ⌥⌘C") { copySelectedStyle() }
                    .keyboardShortcut("c", modifiers: [.option, .command])
                selectionButton("doc.on.clipboard", "粘贴样式 ⌥⌘V") { pasteStyleToSelected() }
                    .keyboardShortcut("v", modifiers: [.option, .command])
                    .disabled(styleClipboard == nil)
                    .opacity(styleClipboard == nil ? 0.4 : 1)
                selectionButton("trash", "删除 ⌫") { deleteSelected() }
                if case .text = selected.kind {
                    selectionButton("pencil", "编辑文字") { startTextEditing(id: selected.id) }
                }
            }
            .position(x: rightMid.x + 20, y: rightMid.y)
        }
    }

    /// 裁剪工具：拖动中显示待裁框，松手后给出确认 / 取消。
    @ViewBuilder
    private var cropOverlay: some View {
        if tool == .crop, let imageRect = cropRect ?? draftRect {
            let frame = viewRect(imageRect)
            Canvas { context, size in
                // 框外压暗，框内保持原样（even-odd 挖洞）。
                var scrim = Path(CGRect(origin: .zero, size: size))
                scrim.addRect(frame)
                context.fill(scrim, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)

            if cropRect != nil {
                HStack(spacing: 8) {
                    Text("\(Int(imageRect.width)) × \(Int(imageRect.height))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                    selectionButton("checkmark", "应用裁剪 ↩") { applyCrop() }
                        .keyboardShortcut(.return, modifiers: [])
                    selectionButton("xmark", "取消裁剪") { cropRect = nil }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .position(x: frame.midX, y: max(18, frame.minY - 22))
            }
        }
    }

    /// 拖动中的裁剪框（draft 只借来当预览，不落成标注）。
    private var draftRect: CGRect? {
        guard case .creating = dragMode, let draft, case .rectangle(let rect) = draft.kind
        else { return nil }
        return rect
    }

    private func viewRect(_ imageRect: CGRect) -> CGRect {
        let origin = viewPoint(CGPoint(x: imageRect.minX, y: imageRect.minY))
        return CGRect(
            origin: origin,
            size: CGSize(
                width: imageRect.width * pointsPerPixel,
                height: imageRect.height * pointsPerPixel
            )
        )
    }

    /// 应用裁剪：换底图，并把标注 / 擦除笔迹按新原点平移。
    private func applyCrop() {
        guard let rect = cropRect, let result = CropOperation.crop(currentBase, to: rect) else { return }

        pushUndo()
        let delta = CropOperation.offset(for: result.rect)
        annotations = CropOperation.shifted(annotations, by: delta)
        eraserStrokes = CropOperation.shifted(eraserStrokes, by: delta)
        croppedImage = result.image
        previewBase = nil
        cropRect = nil
        selectedID = nil
        tool = .select
        ensurePreviewBase()
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
            let height = max(24, font * 1.6 + 8)

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
        VStack(spacing: 0) {
            mainBar
            if showColor || showWidth {
                Divider()
                optionsBar
            }
        }
    }

    private var mainBar: some View {
        HStack(spacing: 6) {
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
                .keyboardShortcut(.delete, modifiers: [])

            separator

            colorButton
            widthButton

            Spacer(minLength: 12)

            zoomControls

            separator

            iconButton(
                "识别文字",
                symbol: "text.viewfinder",
                tint: isLiveTextActive ? Theme.brand : .primary
            ) {
                if isLiveTextActive {
                    isLiveTextActive = false
                } else {
                    isLiveTextActive = true
                    tool = .select
                }
            }
            iconButton("复制", symbol: "doc.on.doc") { exportToCopy() }
            iconButton("保存", symbol: "square.and.arrow.down") { exportToSave() }
            iconButton("钉图", symbol: "pin") { exportToPin() }
            iconButton("关闭", symbol: "xmark") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 点开颜色 / 粗细后出现的第二行（同样通栏，与窗口风格一致）。
    @ViewBuilder
    private var optionsBar: some View {
        HStack(spacing: 14) {
            if showWidth {
                HStack(spacing: 8) {
                    Text(model_toolIsEraser ? "橡皮" : "粗细")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if model_toolIsEraser {
                        Text("\(Int(eraserSize))")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 22, alignment: .trailing)
                        Slider(value: $eraserSize, in: 8...120)
                            .frame(width: 170)
                    } else {
                        Text("\(Int(lineWidth))")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .frame(width: 22, alignment: .trailing)
                        Slider(value: $lineWidth, in: 1...24)
                            .frame(width: 170)
                            .onChange(of: lineWidth) { _, value in
                                applyToSelected { $0.withLineWidth(value) }
                            }
                    }
                }
            }
            if showColor {
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
                                        color == swatch
                                            ? Theme.brand : Color.primary.opacity(0.25),
                                        lineWidth: color == swatch ? 2 : 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            contextualStyleControls
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var model_toolIsEraser: Bool { tool == .eraser }

    private var colorButton: some View {
        Button {
            showColor.toggle()
            if showColor { showWidth = false }
        } label: {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.2))
                .frame(width: 30, height: 26)
        }
        .buttonStyle(.plain)
        .help("颜色")
    }

    private var widthButton: some View {
        Button {
            showWidth.toggle()
            if showWidth { showColor = false }
        } label: {
            Image(systemName: "lineweight")
                .font(.system(size: 15, weight: .regular))
                .frame(width: 30, height: 26)
                .foregroundStyle(showWidth ? Theme.brand : Color.primary)
        }
        .buttonStyle(.plain)
        .help("线条粗细")
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
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
            case .blur:
                separator
                HStack(spacing: 6) {
                    Image(systemName: "drop.halffull")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                    Slider(value: $blurRadius, in: 2...60)
                        .frame(width: 90)
                        .tint(.white)
                        .onChange(of: blurRadius) { _, value in
                            applyToSelected { $0.withBlurRadius(value) }
                        }
                }
            case .magnifier:
                separator
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                    Slider(value: $magnifierZoom, in: 1.5...6)
                        .frame(width: 90)
                        .tint(.white)
                        .onChange(of: magnifierZoom) { _, value in
                            applyToSelected { $0.withMagnifierZoom(value) }
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
            if item != .crop {
                cropRect = nil
            }
            if item.isDrawing {
                selectedID = nil
                // 切到绘制类工具时关闭实况文本，避免抢手势。
                isLiveTextActive = false
            }
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
        tint: Color = .primary,
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

        // 橡皮：画笔式擦除（优先于选择/绘制）。
        if tool == .eraser {
            pushUndo()
            dragMode = .erasing
            let radius = max(3, (eraserSize / 2) / max(0.0001, pointsPerPixel))
            eraserStrokes.append(EraserStroke(points: [startPx], radius: radius))
            lastErasePoint = startPx
            return
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
            // 把该类型的参数也同步到选项条，便于直接微调。
            switch hit.kind {
            case .pixelate(_, let block): mosaicBlock = block
            case .blur(_, let radius): blurRadius = radius
            case .magnifier(_, let zoom): magnifierZoom = zoom
            case .text(_, _, let size), .callout(_, _, _, _, let size): fontSize = size
            default: break
            }
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
        case .erasing:
            if var stroke = eraserStrokes.last {
                stroke.points.append(currentPx)
                eraserStrokes[eraserStrokes.count - 1] = stroke
            }
            lastErasePoint = currentPx
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
        if case .creating = dragMode, tool == .crop {
            // 裁剪：只留框，等用户点确认，不落成标注。
            if let draft, case .rectangle(let rect) = draft.kind, rect.width >= 4, rect.height >= 4 {
                cropRect = rect
            } else {
                cropRect = nil
            }
            self.draft = nil
            dragMode = .none
            return
        }

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
        case .erasing:
            lastErasePoint = nil
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
        case .line:
            return Annotation(kind: .line(from: start, to: current), color: color, lineWidth: lineWidth)
        case .blur:
            return Annotation(kind: .blur(rect, radius: blurRadius), color: color, lineWidth: lineWidth)
        case .magnifier:
            return Annotation(kind: .magnifier(rect, zoom: magnifierZoom), color: color, lineWidth: lineWidth)
        case .pen:
            return Annotation(kind: .pen(points: [start, current]), color: color, lineWidth: lineWidth)
        case .counter:
            return Annotation(
                kind: .counter(center: start, value: counterValue, leader: nil),
                color: color,
                lineWidth: lineWidth
            )
        case .text:
            return Annotation(
                kind: .text(origin: start, string: "", fontSize: fontSize),
                color: color,
                lineWidth: lineWidth
            )
        case .crop:
            // 借矩形当裁剪框的预览，确认前不会变成标注。
            return Annotation(kind: .rectangle(rect), color: color, lineWidth: lineWidth)
        case .select, .eraser:
            return nil
        }
    }

    // MARK: - Editing ops

    private func pushUndo() {
        undoStack.append(
            EditorSnapshot(
                annotations: annotations,
                strokes: eraserStrokes,
                croppedImage: croppedImage
            )
        )
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(
            EditorSnapshot(
                annotations: annotations,
                strokes: eraserStrokes,
                croppedImage: croppedImage
            )
        )
        apply(previous)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(
            EditorSnapshot(
                annotations: annotations,
                strokes: eraserStrokes,
                croppedImage: croppedImage
            )
        )
        apply(next)
    }

    private func apply(_ snapshot: EditorSnapshot) {
        annotations = snapshot.annotations
        eraserStrokes = snapshot.strokes
        // 底图变了要重新栅格化预览。
        if snapshot.croppedImage !== croppedImage {
            croppedImage = snapshot.croppedImage
            previewBase = nil
            ensurePreviewBase()
        }
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
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

    /// 置顶：挪到数组末尾（渲染顺序即数组顺序）。
    private func bringSelectedToFront() {
        guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }),
            index != annotations.count - 1
        else { return }
        pushUndo()
        let annotation = annotations.remove(at: index)
        annotations.append(annotation)
    }

    /// 置底：挪到数组开头。
    private func sendSelectedToBack() {
        guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }),
            index != 0
        else { return }
        pushUndo()
        let annotation = annotations.remove(at: index)
        annotations.insert(annotation, at: 0)
    }

    /// 复制一份并略微错位，便于拖出第二个同类标注。
    private func duplicateSelected() {
        guard let selected = selectedAnnotation else { return }
        pushUndo()

        let shifted = selected.translated(by: CGSize(width: 16, height: 16))
        var kind = shifted.kind
        // 序号 / 气泡复制出来要拿一个新号，避免重号。
        switch kind {
        case .counter(let center, _, let leader):
            kind = .counter(center: center, value: counterValue, leader: leader)
            counterValue += 1
        case .callout(let center, _, let labelOrigin, let string, let size):
            kind = .callout(
                center: center,
                value: counterValue,
                labelOrigin: labelOrigin,
                string: string,
                fontSize: size
            )
            counterValue += 1
        default:
            break
        }

        let copy = Annotation(
            id: UUID(),
            kind: kind,
            color: shifted.color,
            lineWidth: shifted.lineWidth,
            rotation: shifted.rotation
        )
        annotations.append(copy)
        selectedID = copy.id
    }

    /// 复制当前标注的样式（颜色 / 线宽 / 字号 / 马赛克块）。
    private func copySelectedStyle() {
        guard let selected = selectedAnnotation else { return }
        styleClipboard = AnnotationStyle(from: selected)
    }

    /// 把暂存的样式套到当前选中的标注上。
    private func pasteStyleToSelected() {
        guard let style = styleClipboard, let selectedID,
            let index = annotations.firstIndex(where: { $0.id == selectedID })
        else { return }
        pushUndo()
        let styled = style.applied(to: annotations[index])
        annotations[index] = styled
        color = styled.color
        lineWidth = styled.lineWidth
    }

    /// 进入文字内联编辑。
    private func startTextEditing(id: UUID) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        guard case .text(let origin, let string, let size) = annotation.kind else { return }
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
            case .rectangle, .ellipse, .highlight, .pixelate, .pen, .text, .blur, .magnifier:
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
        case .line(let from, let to):
            handles.append((.lineStart, from))
            handles.append((.lineEnd, to))
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
        AnnotationRenderer.render(
            base: currentBase,
            annotations: annotations,
            eraserStrokes: eraserStrokes
        )
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
        // 裁剪框只是预览遮罩，不能烘进底图。
        if let draft, tool != .crop { list.append(draft) }
        let scale = previewBaseScale
        let scaled = list.map { $0.scaled(by: scale) }
        let scaledStrokes = eraserStrokes.map {
            EraserStroke(
                points: $0.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) },
                radius: $0.radius * scale
            )
        }
        return AnnotationRenderer.render(
            base: previewBase,
            annotations: scaled,
            eraserStrokes: scaledStrokes
        )
    }

    private func ensurePreviewBase() {
        let scale = bufferScale
        guard previewBase == nil || abs(previewBaseScale - scale) > 0.0001 else { return }
        previewBase = Self.rasterize(currentBase, scale: scale)
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
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .pixelate(let rect, _),
            .blur(let rect, _), .magnifier(let rect, _):
            return rect.width >= 4 && rect.height >= 4
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 4
        case .line(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= 4
        case .pen(let points):
            return points.count >= 2
        case .text, .counter, .callout:
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
