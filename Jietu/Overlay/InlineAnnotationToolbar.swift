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
    var lineWidth: CGFloat = 8
    var canUndo = false
    var canRedo = false
    /// 第二行展开状态由模型持有，便于宿主视图观察并自适应高度。
    var showColor = false
    var showWidth = false

    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
}

/// 截图选区下方就地弹出的标注工具栏。
///
/// 默认只有一行：工具 + 撤销/重做 + 颜色 + 粗细 + ✗/✓。
/// 颜色、粗细点开后才在第二行展开具体选项。
///
/// @author ixxxxoooo
struct InlineAnnotationToolbar: View {
    @Bindable var model: InlineToolbarModel

    private static let tools: [AnnotationTool] = [
        .rectangle, .ellipse, .arrow, .pen, .highlight, .pixelate, .text, .counter,
    ]

    var body: some View {
        VStack(spacing: 8) {
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

                iconButton("取消", symbol: "xmark", tint: .red) { model.onCancel?() }
                iconButton("确认", symbol: "checkmark", tint: .green) { model.onConfirm?() }
            }

            if model.showColor || model.showWidth {
                expandedOptions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow)
                Color.black.opacity(0.45)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .frame(width: 470)
        .animation(.easeOut(duration: 0.12), value: model.showColor)
        .animation(.easeOut(duration: 0.12), value: model.showWidth)
    }

    /// 只有点了颜色 / 粗细才出现的第二行。
    @ViewBuilder
    private var expandedOptions: some View {
        HStack(spacing: 14) {
            if model.showWidth {
                HStack(spacing: 8) {
                    Text("\(Int(model.lineWidth))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 24, alignment: .trailing)
                    Slider(value: $model.lineWidth, in: 1...24)
                        .frame(width: 170)
                        .tint(.white)
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
