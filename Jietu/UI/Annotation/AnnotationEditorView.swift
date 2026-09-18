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
    /// 原地模式：图片在上、工具栏贴在下方，无窗口边框。
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
    /// 撤销 / 重做的快捷键（设置页「标注编辑」里配，默认 ⌘Z / ⇧⌘Z）。
    var editorShortcuts: EditorShortcuts = .standard

    init(
        baseImage: CGImage,
        inline: Bool = false,
        defaults: AnnotationDefaults = .standard,
        editorShortcuts: EditorShortcuts = .standard,
        onDefaultsChange: ((AnnotationDefaults) -> Void)? = nil,
        onCopy: @escaping (CGImage) -> Void,
        onSave: @escaping (CGImage) -> Void,
        onPin: @escaping (CGImage, CGRect) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.baseImage = baseImage
        self.inline = inline
        self.defaults = defaults
        self.editorShortcuts = editorShortcuts
        self.onDefaultsChange = onDefaultsChange
        self.onCopy = onCopy
        self.onSave = onSave
        self.onPin = onPin
        self.onClose = onClose

        let defaults = defaults.sanitized
        _tool = State(initialValue: defaults.tool)
        _color = State(initialValue: defaults.color)
        _lineWidth = State(initialValue: defaults.lineWidth)
        _highlightColor = State(initialValue: defaults.highlightColor)
        _highlightLineWidth = State(initialValue: defaults.highlightLineWidth)
        _fontSize = State(initialValue: defaults.fontSize)
        _mosaicBlock = State(initialValue: defaults.mosaicBlock)
        _blurRadius = State(initialValue: defaults.blurRadius)
        _eraserSize = State(initialValue: defaults.eraserSize)
        _arrowStyle = State(initialValue: defaults.arrowStyle)
        _shapeFillMode = State(initialValue: defaults.shapeFillMode)
        _textHasStroke = State(initialValue: defaults.textHasStroke)
        _textHasCallout = State(initialValue: defaults.textHasCallout)
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
    /// 荧光笔**自己**的颜色与笔尖粗细（参考 capcap：独立色槽，默认黄）。
    @State private var highlightColor: RGBAColor = .yellow
    @State private var highlightLineWidth: CGFloat = 6
    @State private var fontSize: CGFloat = 22
    @State private var mosaicBlock: CGFloat = 10
    @State private var blurRadius: CGFloat = 12
    @State private var eraserSize: CGFloat = 28
    @State private var arrowStyle: ArrowStyle = .tapered
    @State private var shapeFillMode: ShapeFillMode = .none
    @State private var textHasStroke: Bool = false
    @State private var textHasCallout: Bool = false
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

    @State private var isLiveTextActive = false
    @State private var toolbarHeight: CGFloat = 45

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

    /// 工具栏**一行放得下**所需的最小宽度：再窄右边的按钮就会被窗口裁掉。
    ///
    /// 数值不是手算的，是让 SwiftUI 自己报的（`NSHostingView.fittingSize`）：
    /// `Jietu Dev --selftest-editor <目录>` 会打印出来（加「聚光灯」按钮前实测 967，
    /// 一个工具按钮 30 + 间距 4，故 1001）。
    /// 改工具栏（增减按钮 / 改字号）后跑一下这个自检，把这个数改掉；
    /// `JietuTests` 里有一条用例会盯着「工具栏必须放得进这个宽度」。
    static let toolbarMinWidth: CGFloat = 1001

    /// 带标题栏的编辑器窗口最小宽度（工具栏之外还要留点余量）。
    static let minWindowWidth: CGFloat = max(900, toolbarMinWidth)
    /// 原地编辑窗口的最小宽度：图片可以很窄，但工具栏必须放得下。
    static let minInlineWidth: CGFloat = toolbarMinWidth
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
                // 原地模式：图片在上，工具栏贴在下方。
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
        // 二级选项栏：水平居中悬浮在主工具栏下方（原地模式上方），
        // 不挤压画布高度，由 floatingSurface 承重。
        .overlay(alignment: inline ? .bottom : .top) {
            if activeOptionsTool != nil {
                VStack(spacing: 0) {
                    if inline {
                        optionsBar
                        Color.clear
                            .frame(height: toolbarHeight + 8)
                            .allowsHitTesting(false)
                    } else {
                        Color.clear
                            .frame(height: toolbarHeight + 8)
                            .allowsHitTesting(false)
                        optionsBar
                    }
                }
            }
        }
        .frame(
            minWidth: inline ? Self.minInlineWidth : Self.minWindowWidth,
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
            highlightColor: highlightColor,
            highlightLineWidth: highlightLineWidth,
            fontSize: fontSize,
            mosaicBlock: mosaicBlock,
            blurRadius: blurRadius,
            eraserSize: eraserSize,
            arrowStyle: arrowStyle,
            shapeFillMode: shapeFillMode,
            textHasStroke: textHasStroke,
            textHasCallout: textHasCallout
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
                if isLiveTextActive {
                    LiveTextOverlay(image: renderedImage() ?? currentBase)
                        .frame(width: displayedSize.width, height: displayedSize.height)
                }
                selectionOverlay
                selectionShortcuts
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

    /// 单条标注的操作**不再挂一排浮动按钮**，只保留快捷键。
    ///
    /// 隐藏按钮照样能注册快捷键（参考项目里 ⌘F 也是这么挂的），
    /// 所以功能没丢，只是不再在画布上压一排圆钮。
    @ViewBuilder
    private var selectionShortcuts: some View {
        if selectedAnnotation != nil, editingTextID == nil {
            ZStack {
                Button("置顶") { bringSelectedToFront() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("置底") { sendSelectedToBack() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("复制一份") { duplicateSelected() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("复制样式") { copySelectedStyle() }
                    .keyboardShortcut("c", modifiers: [.option, .command])
                Button("粘贴样式") { pasteStyleToSelected() }
                    .keyboardShortcut("v", modifiers: [.option, .command])
                    .disabled(styleClipboard == nil)
            }
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
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
            InlineTextEditorHost(
                text: $inlineText,
                origin: inlineOriginView,
                fontSize: inlineFontSize * pointsPerPixel,
                color: color,
                hasStroke: textHasStroke,
                hasCallout: textHasCallout,
                onCommit: { commitInlineText() },
                onCancel: { cancelInlineText() }
            )
            .frame(width: displayedSize.width, height: displayedSize.height)
        }
    }

    private var toolbar: some View {
        mainBar
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolbarHeight = $0 }
            // 原地模式窗口是透明的，工具栏得自己兜一层底，否则跟着系统主题切换时看不清。
            .background(inline ? Color(nsColor: .windowBackgroundColor) : Color.clear)
    }

    private var mainBar: some View {
        HStack(spacing: Theme.Size.toolbarItemSpacing) {
            ForEach(AnnotationTool.allCases) { item in
                toolButton(item)
            }

            separator

            iconButton(
                "撤销", symbol: "arrow.uturn.backward",
                help: shortcutHelp("撤销", editorShortcuts.undo),
                key: editorShortcuts.undo?.keyEquivalent,
                modifiers: editorShortcuts.undo?.eventModifiers ?? .command
            ) { undo() }
            .disabled(undoStack.isEmpty)
            .opacity(undoStack.isEmpty ? 0.4 : 1)
            iconButton(
                "重做", symbol: "arrow.uturn.forward",
                help: shortcutHelp("重做", editorShortcuts.redo),
                key: editorShortcuts.redo?.keyEquivalent,
                modifiers: editorShortcuts.redo?.eventModifiers ?? .command
            ) { redo() }
            .disabled(redoStack.isEmpty)
            .opacity(redoStack.isEmpty ? 0.4 : 1)
            iconButton("删除", symbol: "trash", key: .delete, modifiers: []) { deleteSelected() }
                .disabled(selectedID == nil)
                .opacity(selectedID == nil ? 0.4 : 1)

            separator

            // 缩放紧跟在后面：左边不再留一大片空。
            zoomControls

            Spacer(minLength: Theme.Spacing.md)

            separator

            iconButton("复制", symbol: "doc.on.doc") { exportToCopy() }
            iconButton(
                "识别文字",
                symbol: "text.viewfinder",
                tint: isLiveTextActive ? Theme.Colors.brand : Theme.Colors.textSecondary,
                isSelected: isLiveTextActive
            ) {
                if isLiveTextActive {
                    isLiveTextActive = false
                } else {
                    isLiveTextActive = true
                    tool = .select
                }
            }
            iconButton("保存", symbol: "square.and.arrow.down") { exportToSave() }
            iconButton("钉图", symbol: "pin") { exportToPin() }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Options Toolbar

    /// 当前二级参数栏对应的工具：绘图工具下对应自身；选择工具下若有点中对象，则对应选中的对象类型。
    private var activeOptionsTool: AnnotationTool? {
        if tool.isDrawing {
            switch tool {
            case .rectangle, .ellipse, .arrow, .line, .pen, .highlight, .text, .counter, .pixelate, .blur, .eraser:
                return tool
            case .select, .spotlight, .crop:
                return nil
            }
        }
        guard tool == .select, let selected = selectedAnnotation else { return nil }
        switch selected.kind {
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .line: return .line
        case .pen: return .pen
        case .highlight: return .highlight
        case .text, .callout: return .text
        case .counter: return .counter
        case .pixelate: return .pixelate
        case .blur: return .blur
        case .eraser: return .eraser
        case .spotlight: return nil
        }
    }

    /// 二级子工具栏：居中悬浮在主栏下方/上方，磨砂浮动面板样式。
    @ViewBuilder
    private var optionsBar: some View {
        if let optTool = activeOptionsTool {
            HStack(spacing: Theme.Spacing.md) {
                switch optTool {
                case .rectangle, .ellipse:
                    shapeOptions
                case .arrow:
                    arrowOptions
                case .line, .pen:
                    lineOptions
                case .highlight:
                    highlightOptions
                case .text:
                    textOptions
                case .counter:
                    counterOptions
                case .pixelate, .blur:
                    mosaicOptions
                case .eraser:
                    eraserOptions
                case .select, .crop, .spotlight:
                    EmptyView()
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, 7)
            .fixedSize()
            .floatingSurface()
        }
    }

    // MARK: - Sub Options

    private var shapeOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            HUDSlider(value: $lineWidth, range: 1...24, step: 1)
                .onChange(of: lineWidth) { _, val in applyToSelected { $0.withLineWidth(val) } }
            vSeparator
            ColorSwatchesView(selectedColor: $color)
                .onChange(of: color) { _, val in applyToSelected { $0.withColor(val) } }
            vSeparator
            ShapeFillModePicker(
                selectedMode: $shapeFillMode,
                isCircle: activeOptionsTool == .ellipse
            )
            .onChange(of: shapeFillMode) { _, val in applyToSelected { $0.withShapeFillMode(val) } }
        }
    }

    private var arrowOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            HUDSlider(value: $lineWidth, range: 1...24, step: 1)
                .onChange(of: lineWidth) { _, val in applyToSelected { $0.withLineWidth(val) } }
            vSeparator
            ColorSwatchesView(selectedColor: $color)
                .onChange(of: color) { _, val in applyToSelected { $0.withColor(val) } }
            vSeparator
            ArrowStylePicker(selectedStyle: $arrowStyle)
                .onChange(of: arrowStyle) { _, val in applyToSelected { $0.withArrowStyle(val) } }
        }
    }

    private var lineOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            HUDSlider(value: $lineWidth, range: 1...24, step: 1)
                .onChange(of: lineWidth) { _, val in applyToSelected { $0.withLineWidth(val) } }
            vSeparator
            ColorSwatchesView(selectedColor: $color)
                .onChange(of: color) { _, val in applyToSelected { $0.withColor(val) } }
        }
    }

    /// 荧光笔用的是它自己的色槽与笔尖粗细（跟画笔 / 箭头互不影响）。
    private var highlightOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            HUDSlider(
                value: $highlightLineWidth,
                range: Annotation.highlightWidthRange,
                step: 1
            )
            .onChange(of: highlightLineWidth) { _, val in applyToSelected { $0.withLineWidth(val) } }
            vSeparator
            ColorSwatchesView(selectedColor: $highlightColor)
                .onChange(of: highlightColor) { _, val in applyToSelected { $0.withColor(val) } }
        }
    }

    private var textOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            HUDSlider(value: $fontSize, range: 12...72, step: 1)
                .onChange(of: fontSize) { _, val in applyToSelected { $0.withFontSize(val) } }
            vSeparator
            ColorSwatchesView(selectedColor: $color)
                .onChange(of: color) { _, val in applyToSelected { $0.withColor(val) } }
            vSeparator
            HUDCheckboxButton(title: "描边", isSelected: textHasStroke) {
                textHasStroke.toggle()
                applyToSelected { $0.withTextStroke(textHasStroke) }
            }
            HUDCheckboxButton(title: "标注", isSelected: textHasCallout) {
                textHasCallout.toggle()
                applyToSelected { $0.withTextCallout(textHasCallout) }
            }
        }
    }

    private var counterOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            HUDSlider(value: $lineWidth, range: 2...16, step: 1)
                .onChange(of: lineWidth) { _, val in applyToSelected { $0.withLineWidth(val) } }
            vSeparator
            ColorSwatchesView(selectedColor: $color)
                .onChange(of: color) { _, val in applyToSelected { $0.withColor(val) } }
        }
    }

    private var mosaicOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("马赛克颗粒度")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.textSecondary)
            HUDSlider(
                value: activeOptionsTool == .pixelate ? $mosaicBlock : $blurRadius,
                range: 4...40,
                step: 1
            )
            .onChange(of: mosaicBlock) { _, val in
                if activeOptionsTool == .pixelate {
                    applyToSelected { $0.withPixelateBlock(val) }
                }
            }
            .onChange(of: blurRadius) { _, val in
                if activeOptionsTool == .blur {
                    applyToSelected { $0.withBlurRadius(val) }
                }
            }
        }
    }

    private var eraserOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("橡皮大小")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.textSecondary)
            HUDSlider(value: $eraserSize, range: 8...120, step: 2)
        }
    }

    private var vSeparator: some View {
        Rectangle()
            .fill(Theme.Colors.separator)
            .frame(width: Theme.Size.hairline, height: 16)
            .padding(.horizontal, 2)
    }

    private var toolbarTooltipPlacement: TooltipPlacement {
        inline ? .top : .bottom
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.Colors.separator)
            .frame(width: Theme.Size.hairline, height: Theme.Size.toolbarSeparatorHeight)
            .padding(.horizontal, Theme.Spacing.xs)
    }

    private func syncStateFromAnnotation(_ hit: Annotation) {
        if case .highlight = hit.kind {
            highlightColor = hit.color
            highlightLineWidth = hit.lineWidth
        } else {
            color = hit.color
            lineWidth = hit.lineWidth
        }
        arrowStyle = hit.arrowStyle
        shapeFillMode = hit.shapeFillMode
        textHasStroke = hit.textHasStroke
        textHasCallout = hit.textHasCallout
        switch hit.kind {
        case .pixelate(_, let block): mosaicBlock = block
        case .blur(_, let radius): blurRadius = radius
        case .text(_, _, let size), .callout(_, _, _, _, let size): fontSize = size
        default: break
        }
    }

    private func toolButton(_ item: AnnotationTool) -> some View {
        BarButton(
            chrome: .rounded,
            isSelected: tool == item,
            help: item.title,
            tooltipPlacement: toolbarTooltipPlacement,
            action: {
                tool = item
                if item != .crop {
                    cropRect = nil
                }
                if item.isDrawing {
                    selectedID = nil
                    isLiveTextActive = false
                }
            }
        ) {
            Image(systemName: item.symbolName)
                .font(.system(size: Theme.Size.toolbarIconSize, weight: .regular))
                .foregroundStyle(
                    tool == item ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
                )
                .frame(width: Theme.Size.toolbarButtonWidth, height: Theme.Size.toolbarButtonHeight)
        }
    }

    private func iconButton(
        _ title: String,
        symbol: String,
        tint: Color? = nil,
        isSelected: Bool = false,
        help: String? = nil,
        key: KeyEquivalent? = nil,
        modifiers: EventModifiers = .command,
        action: @escaping () -> Void
    ) -> some View {
        BarIconButton(
            title: title,
            systemImage: symbol,
            tint: tint,
            isSelected: isSelected,
            help: help,
            key: key,
            modifiers: modifiers,
            tooltipPlacement: toolbarTooltipPlacement,
            action: action
        )
    }

    /// 悬停提示带上当前快捷键；解绑了就只说动作名。
    private func shortcutHelp(_ title: String, _ hotkey: Hotkey?) -> String {
        guard let hotkey, !hotkey.displayString.isEmpty else { return title }
        return "\(title)（\(hotkey.displayString)）"
    }

    /// 缩放：缩小 / 百分比 / 放大 / 恢复原始大小（图标，不带文字）。
    private var zoomControls: some View {
        HStack(spacing: Theme.Size.toolbarItemSpacing) {
            iconButton("缩小", symbol: "minus.magnifyingglass") { zoomOut() }
            Text("\(Int((zoom * 100).rounded()))%")
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: 42)
            iconButton("放大", symbol: "plus.magnifyingglass") { zoomIn() }
            iconButton("恢复原始大小", symbol: "arrow.counterclockwise") { zoomToOriginal() }
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

        // 橡皮：画笔式擦除（按绘制顺序擦除并恢复底图）。
        if tool == .eraser {
            pushUndo()
            dragMode = .erasing
            let radius = max(3, (eraserSize / 2) / max(0.0001, pointsPerPixel))
            let eraserAnnotation = Annotation(
                kind: .eraser(points: [startPx], radius: radius),
                color: .white,
                lineWidth: radius * 2
            )
            annotations.append(eraserAnnotation)
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
            syncStateFromAnnotation(hit)
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
            if let last = annotations.last, case .eraser(var points, let radius) = last.kind {
                points.append(currentPx)
                annotations[annotations.count - 1].kind = .eraser(points: points, radius: radius)
            }
            lastErasePoint = currentPx
        case .creating(let start):
            // 画笔与荧光笔都是连续笔迹：点越攒越多，而不是每帧只留起终点。
            if tool == .pen, case .pen(var points)? = draft?.kind {
                points.append(currentPx)
                draft?.kind = .pen(points: points)
            } else if tool == .highlight, case .highlight(var points)? = draft?.kind {
                points.append(currentPx)
                draft?.kind = .highlight(points: points)
            } else {
                draft = makeDraft(tool: tool, start: start, current: currentPx)
            }
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
            return Annotation(
                kind: .rectangle(rect),
                color: color,
                lineWidth: lineWidth,
                shapeFillMode: shapeFillMode
            )
        case .ellipse:
            return Annotation(
                kind: .ellipse(rect),
                color: color,
                lineWidth: lineWidth,
                shapeFillMode: shapeFillMode
            )
        case .highlight:
            // 荧光笔是**涂**出来的一条笔迹，不是拉框（参考 capcap 的高亮笔）。
            return Annotation(
                kind: .highlight(points: [start, current]),
                color: highlightColor,
                lineWidth: highlightLineWidth
            )
        case .spotlight:
            return Annotation(kind: .spotlight(rect), color: color, lineWidth: lineWidth)
        case .pixelate:
            return Annotation(kind: .pixelate(rect, block: mosaicBlock), color: color, lineWidth: lineWidth)
        case .arrow:
            return Annotation(
                kind: .arrow(from: start, to: current, control: nil),
                color: color,
                lineWidth: lineWidth,
                arrowStyle: arrowStyle
            )
        case .line:
            return Annotation(kind: .line(from: start, to: current), color: color, lineWidth: lineWidth)
        case .blur:
            return Annotation(kind: .blur(rect, radius: blurRadius), color: color, lineWidth: lineWidth)
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
                lineWidth: lineWidth,
                textHasStroke: textHasStroke,
                textHasCallout: textHasCallout
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
            rotation: shifted.rotation,
            arrowStyle: shifted.arrowStyle,
            shapeFillMode: shifted.shapeFillMode,
            textHasStroke: shifted.textHasStroke,
            textHasCallout: shifted.textHasCallout
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
        syncStateFromAnnotation(styled)
    }

    /// 进入文字内联编辑。
    private func startTextEditing(id: UUID) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        guard case .text(let origin, let string, let size) = annotation.kind else { return }
        selectedID = id
        syncStateFromAnnotation(annotation)
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
            annotations[index] = annotations[index]
                .withText(trimmed)
                .withColor(color)
                .withTextStroke(textHasStroke)
                .withTextCallout(textHasCallout)
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
        syncStateFromAnnotation(hit)
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
            case .rectangle, .ellipse, .spotlight, .highlight, .pixelate, .pen, .text, .blur:
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

        if annotation.supportsRotation {
            handles.append((.rotate, ShapeGeometry.rotateHandle(for: annotation, distance: 28)))
        }
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
        case .rectangle(let rect), .ellipse(let rect), .spotlight(let rect), .pixelate(let rect, _),
            .blur(let rect, _):
            return rect.width >= 4 && rect.height >= 4
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 4
        case .line(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= 4
        case .pen(let points), .highlight(let points):
            return points.count >= 2
        case .text, .counter, .callout, .eraser:
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
