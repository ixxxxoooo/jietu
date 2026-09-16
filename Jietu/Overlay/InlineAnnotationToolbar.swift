import AppKit
import Observation
import SwiftUI

/// 原地标注工具栏的状态模型。
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

/// 原地标注的**主工具栏**：固定尺寸，展开选项时也不重算，避免闪烁。
///
/// 表面走 `FloatingSurface`（磨砂 + scrim），控件用 `BarButton` 家族：
/// 选中常驻 `controlSurface`，未选中悬停才压一层墨。
///
/// @author ixxxxoooo
struct InlineMainToolbar: View {
    @Bindable var model: InlineToolbarModel

    private static let tools: [AnnotationTool] = [
        .select, .rectangle, .ellipse, .arrow, .line, .pen, .highlight, .pixelate, .blur,
        .magnifier, .text, .counter, .eraser,
    ]

    var body: some View {
        HStack(spacing: Theme.Size.toolbarItemSpacing) {
            ForEach(Self.tools) { item in
                toolButton(item)
            }

            separator

            BarIconButton(
                title: "撤销",
                systemImage: "arrow.uturn.backward",
                isSelected: false,
                action: { model.onUndo?() }
            )
            .disabled(!model.canUndo)
            .opacity(model.canUndo ? 1 : 0.4)

            BarIconButton(
                title: "重做",
                systemImage: "arrow.uturn.forward",
                action: { model.onRedo?() }
            )
            .disabled(!model.canRedo)
            .opacity(model.canRedo ? 1 : 0.4)

            separator

            colorButton
            widthButton

            Spacer(minLength: Theme.Spacing.xl)

            BarIconButton(title: "下载", systemImage: "square.and.arrow.down") {
                model.onSave?()
            }
            BarIconButton(title: "钉图", systemImage: "pin") {
                model.onPin?()
            }
            BarIconButton(
                title: "识别文字",
                systemImage: "text.viewfinder",
                tint: model.isLiveTextActive
                    ? Theme.Colors.brand : Theme.Colors.textSecondary,
                isSelected: model.isLiveTextActive
            ) {
                if model.isLiveTextActive {
                    model.isLiveTextActive = false
                } else {
                    model.isLiveTextActive = true
                    model.tool = .select
                }
            }
            BarIconButton(
                title: "取消",
                systemImage: "xmark",
                tint: Theme.Colors.destructive
            ) {
                model.onCancel?()
            }
            BarIconButton(
                title: "确认",
                systemImage: "checkmark",
                tint: Theme.Colors.success
            ) {
                model.onConfirm?()
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .fixedSize()
        .floatingSurface()
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.Colors.separator)
            .frame(width: Theme.Size.hairline, height: Theme.Size.toolbarSeparatorHeight)
            .padding(.horizontal, Theme.Spacing.xs)
    }

    private var colorButton: some View {
        BarButton(chrome: .rounded, isSelected: model.showColor) {
            model.showColor.toggle()
            if model.showColor { model.showWidth = false }
        } label: {
            Circle()
                .fill(model.color.swiftUIColor)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Theme.Colors.border, lineWidth: 1.2))
                .frame(width: Theme.Size.toolbarButtonWidth, height: Theme.Size.toolbarButtonHeight)
        }
        .help("颜色")
    }

    private var widthButton: some View {
        BarIconButton(
            title: "线条粗细",
            systemImage: "lineweight",
            isSelected: model.showWidth
        ) {
            model.showWidth.toggle()
            if model.showWidth { model.showColor = false }
        }
    }

    private func toolButton(_ item: AnnotationTool) -> some View {
        BarButton(chrome: .rounded, isSelected: model.tool == item) {
            model.tool = item
            if item.isDrawing { model.isLiveTextActive = false }
        } label: {
            Image(systemName: item.symbolName)
                .font(.system(size: Theme.Size.toolbarIconSize, weight: .regular))
                .foregroundStyle(
                    model.tool == item ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
                )
                .frame(
                    width: Theme.Size.toolbarButtonWidth, height: Theme.Size.toolbarButtonHeight)
        }
        .help(item.title)
    }
}

/// 原地标注的**展开选项条**（颜色 / 粗细）：单独一条，出现在主栏下方。
///
/// @author ixxxxoooo
struct InlineOptionsToolbar: View {
    @Bindable var model: InlineToolbarModel

    var body: some View {
        HStack(spacing: Theme.Spacing.xxl) {
            if model.showWidth {
                HStack(spacing: Theme.Spacing.md) {
                    Text(model.tool == .eraser ? "橡皮" : "\(Int(model.lineWidth))")
                        .font(Theme.Typography.numeric)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .frame(width: 34, alignment: .trailing)
                    if model.tool == .eraser {
                        Slider(value: $model.eraserSize, in: 8...120)
                            .frame(width: 170)
                    } else {
                        Slider(value: $model.lineWidth, in: 1...24)
                            .frame(width: 170)
                    }
                }
            }
            if model.showColor {
                HStack(spacing: Theme.Spacing.lg) {
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
                                            ? Theme.Colors.textPrimary : Theme.Colors.border,
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
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .fixedSize()
        .floatingSurface()
    }
}
