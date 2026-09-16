import AppKit
import Observation
import SwiftUI

/// 就地标注工具栏的状态模型。
///
/// @author ixxxxoooo
@Observable
final class InlineToolbarModel {
    var tool: AnnotationTool = .rectangle
    var color: RGBAColor = .red
    var lineWidth: CGFloat = 7
    var eraserSize: CGFloat = 28
    var mosaicBlock: CGFloat = 12
    var blurRadius: CGFloat = 12
    var magnifierZoom: CGFloat = 2
    var canUndo = false
    var canRedo = false
    /// 展开状态由模型持有，便于宿主视图观察并自适应高度。
    var showColor = false
    var showWidth = false
    /// 实况文本是否开启（OCR 按钮触发）。
    var isLiveTextActive = false

    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
}

/// 就地标注的**主工具栏**：固定尺寸，展开选项时也不重算，避免闪烁。
///
/// @author ixxxxoooo
struct InlineMainToolbar: View {
    @Bindable var model: InlineToolbarModel

    private static let tools: [AnnotationTool] = [
        .select, .rectangle, .ellipse, .arrow, .line, .pen, .highlight, .pixelate, .blur,
        .magnifier, .text, .counter, .eraser,
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.tools) { item in
                toolButton(item)
            }

            separator

            iconButton("撤销", symbol: "arrow.uturn.backward") { model.onUndo?() }
                .disabled(!model.canUndo)
            iconButton("重做", symbol: "arrow.uturn.forward") { model.onRedo?() }
                .disabled(!model.canRedo)

            separator

            colorButton
            widthButton

            Spacer(minLength: 12)

            iconButton("下载", symbol: "square.and.arrow.down") { model.onSave?() }
            iconButton("钉图", symbol: "pin") { model.onPin?() }
            iconButton(
                "识别文字",
                symbol: "text.viewfinder",
                tint: model.isLiveTextActive ? Theme.selectionGreen : .white
            ) {
                if model.isLiveTextActive {
                    model.isLiveTextActive = false
                } else {
                    model.isLiveTextActive = true
                    model.tool = .select
                }
            }
            iconButton("取消", symbol: "xmark", tint: .red) { model.onCancel?() }
            iconButton("确认", symbol: "checkmark", tint: .green) { model.onConfirm?() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .background(FrostedBar())
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }

    private var colorButton: some View {
        Button {
            model.showColor.toggle()
            if model.showColor { model.showWidth = false }
        } label: {
            Circle()
                .fill(model.color.swiftUIColor)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.2))
                .frame(width: 30, height: 26)
        }
        .buttonStyle(.plain)
        .help("颜色")
    }

    private var widthButton: some View {
        Button {
            model.showWidth.toggle()
            if model.showWidth { model.showColor = false }
        } label: {
            Image(systemName: "lineweight")
                .font(.system(size: 15, weight: .regular))
                .frame(width: 30, height: 26)
                .foregroundStyle(model.showWidth ? Theme.selectionGreen : Color.white.opacity(0.9))
        }
        .buttonStyle(.plain)
        .help("线条粗细")
    }

    private func toolButton(_ item: AnnotationTool) -> some View {
        Button {
            model.tool = item
            if item.isDrawing { model.isLiveTextActive = false }
        } label: {
            Image(systemName: item.symbolName)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 30, height: 26)
                .foregroundStyle(
                    model.tool == item ? Theme.selectionGreen : Color.white.opacity(0.9)
                )
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
}

/// 就地标注的**展开选项条**（颜色 / 粗细）：单独一条，出现在主栏下方。
///
/// @author ixxxxoooo
struct InlineOptionsToolbar: View {
    @Bindable var model: InlineToolbarModel

    var body: some View {
        HStack(spacing: 14) {
            if model.showWidth {
                HStack(spacing: 8) {
                    Text(model.tool == .eraser ? "橡皮" : "\(Int(model.lineWidth))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, alignment: .trailing)
                    if model.tool == .eraser {
                        Slider(value: $model.eraserSize, in: 8...120)
                            .frame(width: 170)
                            .tint(.white)
                    } else {
                        Slider(value: $model.lineWidth, in: 1...24)
                            .frame(width: 170)
                            .tint(.white)
                    }
                }
            }
            if model.showColor {
                HStack(spacing: 10) {
                    ForEach(RGBAColor.palette, id: \.self) { swatch in
                        Button {
                            model.color = swatch
                        } label: {
                            Circle()
                                .fill(swatch.swiftUIColor)
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Circle().strokeBorder(
                                        model.color == swatch
                                            ? Color.white : Color.white.opacity(0.2),
                                        lineWidth: model.color == swatch ? 2 : 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .background(FrostedBar())
    }
}

/// 磨砂深色圆角条。
///
/// @author ixxxxoooo
struct FrostedBar: View {
    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow)
            Color.black.opacity(0.45)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}
