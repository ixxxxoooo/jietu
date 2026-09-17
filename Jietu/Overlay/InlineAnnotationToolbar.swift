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
    var canUndo = false
    var canRedo = false
    /// 展开状态由模型持有，便于宿主视图观察并自适应高度。
    var showColor = false
    var showWidth = false
    /// 「滚动截图」的两个选项（手动 / 自动）展开。
    var showScroll = false
    /// 展开时子工具栏要对齐到哪个按钮的 midX（工具条自身坐标，由 SwiftUI 上报）。
    var optionsAnchorX: CGFloat = 0
    /// 实况文本是否开启（OCR 按钮触发）。
    var isLiveTextActive = false

    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    /// 选了「手动 / 自动滚动」：把当前选区接着往下滚成一张长图。
    var onScrollCapture: ((ScrollingCaptureSession.Mode) -> Void)?
    /// 点了「录屏」：拿当前选区去录（选区交给外面，遮罩收掉、上红框与控制条）。
    var onRecord: (() -> Void)?
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
        .text, .counter, .eraser,
    ]

    /// 上报子工具栏锚点用的坐标空间。
    private static let space = "inlineToolbar"

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
                title: "滚动截图",
                systemImage: "scroll",
                isSelected: model.showScroll
            ) {
                model.showScroll.toggle()
                if model.showScroll {
                    model.showColor = false
                    model.showWidth = false
                }
            }
            .help("滚动长图：这块区域接着往下滚成一张长图")
            .modifier(
                OptionsAnchorReporter(
                    isExpanded: model.showScroll, space: Self.space, model: model))

            // 录屏：拿当前这块选区去录（点了收掉遮罩、上红框与「准备录制」控制条）。
            BarIconButton(title: "录屏", systemImage: "record.circle") {
                model.onRecord?()
            }
            .help("录这块区域：收掉遮罩、上红框，点「开始」才真开录")

            BarIconButton(title: "保存", systemImage: "square.and.arrow.down") {
                model.onSave?()
            }
            BarIconButton(title: "钉图", systemImage: "pin") {
                model.onPin?()
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
        .coordinateSpace(name: Self.space)
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
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Theme.Colors.border, lineWidth: 1))
                .frame(width: Theme.Size.toolbarButtonWidth, height: Theme.Size.toolbarButtonHeight)
        }
        .help("颜色")
        .modifier(
            OptionsAnchorReporter(
                isExpanded: model.showColor, space: Self.space, model: model))
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
        .modifier(
            OptionsAnchorReporter(
                isExpanded: model.showWidth, space: Self.space, model: model))
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
            if model.showScroll {
                HStack(spacing: Theme.Spacing.md) {
                    // 与滚动长图的模式条同一套说法：只回答「谁来滚」。
                    Image(systemName: "scroll")
                        .font(Theme.Typography.bar)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text("谁来滚")
                        .font(Theme.Typography.bar)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    scrollChoice("手动滚动", systemImage: "hand.draw") {
                        model.onScrollCapture?(.manual)
                    }
                    .help("点完自己把鼠标放进选区往下滚")
                    scrollChoice("自动滚动", systemImage: "wand.and.rays") {
                        model.onScrollCapture?(.automatic)
                    }
                    .help("由 Jietu 自己滚（需要辅助功能权限）")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .fixedSize()
        .floatingSurface()
    }

    /// 滚动截图的两个选项：图标 + 文字，点一下就用这个模式开跑。
    private func scrollChoice(
        _ title: String, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        BarButton(chrome: .rounded, action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(Theme.Typography.chip)
                Text(title)
                    .font(Theme.Typography.bar)
            }
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: Theme.Size.barButtonHeight)
        }
    }
}


/// 把自己在工具条里的 midX 报给模型：展开子工具栏时据此居中到被点的按钮下方。
///
/// @author ixxxxoooo
private struct OptionsAnchorReporter: ViewModifier {
    let isExpanded: Bool
    let space: String
    let model: InlineToolbarModel

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        guard isExpanded else { return }
                        model.optionsAnchorX = proxy.frame(in: .named(space)).midX
                    }
                    .onChange(of: isExpanded) { _, expanded in
                        guard expanded else { return }
                        model.optionsAnchorX = proxy.frame(in: .named(space)).midX
                    }
            }
        )
    }
}
