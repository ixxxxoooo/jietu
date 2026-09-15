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
    /// 是否已有选区（决定 ✓ 是否可用）。
    var canConfirm = false

    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
}

/// 截图选区下方就地弹出的标注工具栏。
///
/// @author ixxxxoooo
struct InlineAnnotationToolbar: View {
    @Bindable var model: InlineToolbarModel

    private static let tools: [AnnotationTool] = [
        .rectangle, .ellipse, .arrow, .pen, .highlight, .pixelate, .text, .counter,
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Self.tools) { item in
                    toolButton(item)
                }

                Divider().frame(height: 20)

                colorControl
                widthControl

                Divider().frame(height: 20)

                iconButton("撤销", symbol: "arrow.uturn.backward") {}
                    .disabled(true)

                Spacer(minLength: 10)

                iconButton("取消", symbol: "xmark") { model.onCancel?() }
                confirmButton
            }

            HStack(spacing: 8) {
                ForEach(RGBAColor.palette, id: \.self) { swatch in
                    Button {
                        model.color = swatch
                    } label: {
                        Circle()
                            .fill(swatch.swiftUIColor)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(
                                    model.color == swatch ? Color.white : Color.white.opacity(0.25),
                                    lineWidth: model.color == swatch ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 固定宽度：否则 NSHostingView 的 fittingSize 会算窄，内容被裁切。
        .frame(width: 700)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func toolButton(_ item: AnnotationTool) -> some View {
        Button {
            model.tool = item
        } label: {
            Image(systemName: item.symbolName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(model.tool == item ? Theme.brand : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    private var colorControl: some View {
        Button {} label: {
            Circle()
                .fill(model.color.swiftUIColor)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .help("颜色（下方调色板）")
    }

    private var widthControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "lineweight")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
            Slider(value: $model.lineWidth, in: 1...16)
                .frame(width: 70)
        }
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

    private var confirmButton: some View {
        Button { model.onConfirm?() } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 24)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(model.canConfirm ? Theme.brand : Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .disabled(!model.canConfirm)
        .help("确认")
    }
}
