import AppKit
import SwiftUI

/// 标注编辑器主界面。
///
/// 预览策略：把原图栅格化到与显示像素匹配的底图，再用**同一个渲染器**
/// （`AnnotationRenderer`）把标注烘焙上去显示。这样预览和导出走同一条代码路径，
/// 避免「编辑时看到的样子和保存出来的不一样」。
///
/// 缩放：`zoom` 是相对**原始大小**（像素 ÷ 屏幕缩放）的比例，1.0 表示原始大小。
/// 窗口可自由调整大小，内容放进双轴 `ScrollView`，超出可视区时可滚动查看。
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

    @State private var annotations: [Annotation] = []
    @State private var redoStack: [Annotation] = []
    @State private var tool: AnnotationTool = .rectangle
    @State private var color: RGBAColor = .red
    @State private var lineWidth: CGFloat = 3
    @State private var draftShape: Annotation.Shape?
    @State private var counterValue = 1

    @State private var isTextPromptPresented = false
    @State private var textInput = ""
    @State private var textOrigin: CGPoint = .zero

    @State private var previewBase: CGImage?
    @State private var previewBaseScale: CGFloat = -1

    @State private var availableSize: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var hasUserZoomed = false
    @State private var hasInitialized = false

    @State private var ocrText = ""
    @State private var isOCRPresented = false
    @State private var isRecognizing = false

    /// 画布在窗口中的全局坐标，用于「原地钉图」。
    @State private var canvasGlobalFrame: CGRect = .zero

    // MARK: - Layout

    static let toolbarHeight: CGFloat = 44
    static let padding: CGFloat = 10
    /// 最小窗口尺寸：不能小于工具栏一排按钮所需宽度，避免工具栏被挤压。
    static let minWindowWidth: CGFloat = 1010
    static let minWindowHeight: CGFloat = 430
    private static let minZoom: CGFloat = 0.1
    private static let maxZoom: CGFloat = 8

    /// 原始大小（point）：图像像素 ÷ 屏幕缩放。
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

    /// 预览底图相对原图像素的缩放比。放大（zoom > 1）时不再生成更大的缓冲，
    /// 交给 SwiftUI 插值放大，避免 6K 图放大后爆内存。
    private var bufferScale: CGFloat { min(zoom, 1) }

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
        .onAppear { ensurePreviewBase() }
        .onChange(of: bufferScale) { _, _ in ensurePreviewBase() }
        .alert("输入文字", isPresented: $isTextPromptPresented) {
            TextField("文字", text: $textInput)
            Button("确定") { commitText() }
            Button("取消", role: .cancel) { textInput = "" }
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
                    .overlay(
                        Rectangle()
                            .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
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
                Slider(value: $lineWidth, in: 1...12)
                    .frame(width: 70)
            }

            Divider().frame(height: 20)

            zoomControls

            Spacer(minLength: 8)

            iconButton("撤销", symbol: "arrow.uturn.backward") { undo() }
                .disabled(annotations.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
            iconButton("重做", symbol: "arrow.uturn.forward") { redo() }
                .disabled(redoStack.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            iconButton("清空", symbol: "trash") { clear() }
                .disabled(annotations.isEmpty)

            Divider().frame(height: 20)

            iconButton("复制", symbol: "doc.on.doc") { exportToCopy() }
            iconButton("保存", symbol: "square.and.arrow.down") { exportToSave() }
            iconButton("OCR", symbol: "text.viewfinder") { exportOCR() }
                .disabled(isRecognizing)
            iconButton("钉图", symbol: "pin") { exportToPin() }
            iconButton("关闭", symbol: "xmark") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 10)
        // 固定最小宽度：窗口再窄也不会把工具栏挤成一团。
        .frame(minWidth: Self.minWindowWidth, maxWidth: .infinity, minHeight: Self.toolbarHeight, maxHeight: Self.toolbarHeight)
        .fixedSize(horizontal: false, vertical: true)
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

    private func toolButton(_ item: AnnotationTool) -> some View {
        Button {
            tool = item
            draftShape = nil
        } label: {
            Image(systemName: item.symbolName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(tool == item ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tool == item ? Theme.brand : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    private func colorButton(_ swatch: RGBAColor) -> some View {
        Button {
            color = swatch
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
        }
        .buttonStyle(.borderless)
        .help(title)
    }

    // MARK: - Gesture

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = imagePoint(from: value.startLocation)
                let current = imagePoint(from: value.location)
                draftShape = draftShape(for: tool, start: start, current: current)
            }
            .onEnded { value in
                let start = imagePoint(from: value.startLocation)
                let current = imagePoint(from: value.location)
                draftShape = nil

                switch tool {
                case .text:
                    textOrigin = start
                    textInput = ""
                    isTextPromptPresented = true
                case .counter:
                    commit(
                        Annotation(
                            shape: .counter(center: start, value: counterValue),
                            color: color,
                            lineWidth: lineWidth
                        )
                    )
                    counterValue += 1
                default:
                    if let shape = draftShape(for: tool, start: start, current: current),
                        isValid(shape)
                    {
                        commit(Annotation(shape: shape, color: color, lineWidth: lineWidth))
                    }
                }
            }
    }

    // MARK: - Editing

    private func commit(_ annotation: Annotation) {
        annotations.append(annotation)
        redoStack.removeAll()
    }

    private func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
    }

    private func redo() {
        guard let restored = redoStack.popLast() else { return }
        annotations.append(restored)
    }

    private func clear() {
        annotations.removeAll()
        redoStack.removeAll()
    }

    private func commitText() {
        let trimmed = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        textInput = ""
        guard !trimmed.isEmpty else { return }
        commit(
            Annotation(
                shape: .text(origin: textOrigin, string: trimmed, fontSize: max(14, lineWidth * 6)),
                color: color,
                lineWidth: lineWidth
            )
        )
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

    /// OCR：识别当前成图里的文字，复制到剪贴板并弹窗展示。
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
        if let draftShape {
            list.append(Annotation(shape: draftShape, color: color, lineWidth: lineWidth))
        }
        let scale = previewBaseScale
        let scaled = list.map { $0.scaled(by: scale) }
        let block = max(1, Int((CGFloat(AnnotationRenderer.mosaicBlock) * scale).rounded()))
        return AnnotationRenderer.render(base: previewBase, annotations: scaled, mosaicBlock: block)
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

    /// 视图坐标（point）→ 图像像素坐标。
    private func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        let pointsPerPixel = zoom / max(1, displayScale)
        guard pointsPerPixel > 0 else { return .zero }
        return CGPoint(x: viewPoint.x / pointsPerPixel, y: viewPoint.y / pointsPerPixel)
    }

    private func draftShape(
        for tool: AnnotationTool,
        start: CGPoint,
        current: CGPoint
    ) -> Annotation.Shape? {
        switch tool {
        case .rectangle:
            return .rectangle(normalizedRect(start, current))
        case .ellipse:
            return .ellipse(normalizedRect(start, current))
        case .pixelate:
            return .pixelate(normalizedRect(start, current))
        case .arrow:
            return .arrow(from: start, to: current)
        case .text, .counter:
            return nil
        }
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    private func isValid(_ shape: Annotation.Shape) -> Bool {
        switch shape {
        case .rectangle(let rect), .ellipse(let rect), .pixelate(let rect):
            return rect.width >= 4 && rect.height >= 4
        case .arrow(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) >= 4
        case .text, .counter:
            return true
        }
    }

    // MARK: - Window sizing

    /// 编辑器初始窗口尺寸：默认按原始大小，超过屏幕 90% 时等比缩小。
    /// 宽度不小于 `minWindowWidth`，避免工具栏被挤压。
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
