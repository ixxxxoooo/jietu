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
    /// 展开状态由模型持有，便于宿主视图观察并自适应高度。
    var showColor = false
    var showWidth = false

    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
}

/// 截图选区下方就地弹出的标注工具栏。
///
/// 主工具栏一条，颜色/粗细点开后是**下方另一条独立的小工具栏**（中间留空隙）。
/// 与编辑窗口工具一致：含选择工具，可拖拽 / 旋转 / 改端点。
///
/// @author ixxxxoooo
struct InlineAnnotationToolbar: View {
    @Bindable var model: InlineToolbarModel

    private static let tools: [AnnotationTool] = [
        .select, .rectangle, .ellipse, .arrow, .pen, .highlight, .pixelate, .text, .counter,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mainBar
                .frame(width: 560)
            if model.showColor || model.showWidth {
                // 对齐到颜色 / 粗细两个按钮下方（靠右）。
                optionsBar
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 560, alignment: .trailing)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.showColor)
        .animation(.easeOut(duration: 0.12), value: model.showWidth)
    }

    private var mainBar: some View {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(FrostedBar())
    }

    /// 点开颜色 / 粗细后出现的第二行——**独立的一条**，与主工具栏中间有缝隙。
    @ViewBuilder
    private var optionsBar: some View {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
