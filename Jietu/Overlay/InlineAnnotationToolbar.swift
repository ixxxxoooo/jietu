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

    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
}

/// 截图选区下方就地弹出的标注工具栏。
///
/// 风格参考：高斯模糊深色胶囊、图标无背景框、选中项用颜色区分、
/// 粗细为数字 + 滑杆、颜色为圆点。
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

                Spacer(minLength: 12)

                iconButton("取消", symbol: "xmark", tint: .red) { model.onCancel?() }
                iconButton("确认", symbol: "checkmark", tint: .green) { model.onConfirm?() }
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text("\(Int(model.lineWidth))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 24, alignment: .trailing)
                    Slider(value: $model.lineWidth, in: 1...24)
                        .frame(width: 170)
                        .tint(.white)
                }

                separator

                HStack(spacing: 10) {
                    ForEach(RGBAColor.palette, id: \.self) { swatch in
                        Button {
                            model.color = swatch
                        } label: {
                            Circle()
                                .fill(swatch.swiftUIColor)
                                .frame(width: 18, height: 18)
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

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // 固定宽度：否则 NSHostingView 的 fittingSize 会算窄，内容被裁切。
        .frame(width: 640)
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
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
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
