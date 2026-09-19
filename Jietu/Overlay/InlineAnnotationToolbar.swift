import AppKit
import Observation
import SwiftUI

/// 原地标注工具栏的状态模型。
///
/// @author ixxxxoooo
@Observable
final class InlineToolbarModel {
    var tool: AnnotationTool? = nil
    var color: RGBAColor = .red
    var lineWidth: CGFloat = 7
    /// 荧光笔**自己**的颜色与笔尖粗细（参考 capcap：独立色槽，默认黄）。
    var highlightColor: RGBAColor = .yellow
    var highlightLineWidth: CGFloat = 6
    var fontSize: CGFloat = 20
    var eraserSize: CGFloat = 28
    var mosaicBlock: CGFloat = 12
    var blurRadius: CGFloat = 12
    var arrowStyle: ArrowStyle = .tapered
    var shapeFillMode: ShapeFillMode = .none
    var textHasStroke: Bool = false
    var textHasCallout: Bool = false
    var canUndo = false
    var canRedo = false
    /// 「滚动截图」的两个选项（手动 / 自动）展开。
    var showScroll = false
    /// 实况文本是否开启（OCR 按钮触发）。
    var isLiveTextActive = false
    /// 是否为从浮窗恢复的静态图片（不显示滚动截图和录屏）。
    var isRestoredImage = false
    /// 撤销 / 重做的当前快捷键；只用于把组合键显示在 tooltip 里（真正按键由画布处理）。
    var editorShortcuts: EditorShortcuts = .standard

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
    var onApplyCrop: (() -> Void)?
    var onCancelCrop: (() -> Void)?

    /// 是否应展示二级子工具栏。
    var isSubToolbarVisible: Bool {
        if showScroll { return true }
        guard let tool else { return false }
        switch tool {
        case .select, .spotlight:
            return false
        case .crop:
            return true
        case .rectangle, .ellipse, .arrow, .line, .pen, .highlight, .text, .pixelate, .blur, .counter, .eraser:
            return true
        }
    }
}

/// 原地标注的**主工具栏**：固定尺寸，控件用 `BarButton` 家族。
///
/// 选中常驻 `controlSurface`，未选中悬停才压一层墨。
///
/// @author ixxxxoooo
struct InlineMainToolbar: View {
    @Bindable var model: InlineToolbarModel

    private static let tools: [AnnotationTool] = AnnotationTool.allCases

    /// 悬停提示带上当前快捷键；解绑了就只说动作名。
    private static func shortcutHelp(_ title: String, _ hotkey: Hotkey?) -> String {
        guard let hotkey, !hotkey.displayString.isEmpty else { return title }
        return "\(title)（\(hotkey.displayString)）"
    }

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
                help: Self.shortcutHelp("撤销", model.editorShortcuts.undo),
                action: { model.onUndo?() }
            )
            .disabled(!model.canUndo)
            .opacity(model.canUndo ? 1 : 0.4)

            BarIconButton(
                title: "重做",
                systemImage: "arrow.uturn.forward",
                help: Self.shortcutHelp("重做", model.editorShortcuts.redo),
                action: { model.onRedo?() }
            )
            .disabled(!model.canRedo)
            .opacity(model.canRedo ? 1 : 0.4)

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
                    model.showScroll = false
                }
            }

            if !model.isRestoredImage {
                BarIconButton(
                    title: "滚动截图",
                    systemImage: "scroll",
                    isSelected: model.showScroll
                ) {
                    model.showScroll.toggle()
                    if model.showScroll {
                        model.tool = nil
                    }
                }

                // 录屏：拿当前这块选区去录（点了收掉遮罩、上红框与「准备录制」控制条）。
                BarIconButton(title: "录屏", systemImage: "record.circle") {
                    model.onRecord?()
                }
            }

            BarIconButton(
                title: "保存",
                systemImage: "square.and.arrow.down",
                help: "保存 (⌘S)",
                key: "s"
            ) {
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
        .fixedSize()
        .floatingSurface()
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.Colors.separator)
            .frame(width: Theme.Size.hairline, height: Theme.Size.toolbarSeparatorHeight)
            .padding(.horizontal, Theme.Spacing.xs)
    }

    private func toolButton(_ item: AnnotationTool) -> some View {
        BarButton(
            chrome: .rounded,
            isSelected: model.tool == item,
            help: item.title
        ) {
            if model.tool == item {
                model.tool = nil
            } else {
                model.tool = item
                model.showScroll = false
                if item.isDrawing { model.isLiveTextActive = false }
            }
        } label: {
            Image(systemName: item.symbolName)
                .font(.system(size: Theme.Size.toolbarIconSize, weight: .regular))
                .foregroundStyle(
                    model.tool == item ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
                )
                .frame(
                    width: Theme.Size.toolbarButtonWidth, height: Theme.Size.toolbarButtonHeight)
        }
    }
}

/// 原地标注的**专属二级子工具栏**（粗细 / 颜色 / 模式等）：单独一条，居中出现在主栏下方。
///
/// @author ixxxxoooo
struct InlineOptionsToolbar: View {
    @Bindable var model: InlineToolbarModel

    var body: some View {
        if model.isSubToolbarVisible {
            HStack(spacing: Theme.Spacing.md) {
                if model.showScroll {
                    scrollOptions
                } else if let tool = model.tool {
                    switch tool {
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
                    case .crop:
                        cropOptions
                    case .select, .spotlight:
                        EmptyView()
                    }
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
            HUDSlider(value: $model.lineWidth, range: 1...24, step: 1)
            vSeparator
            ColorSwatchesView(selectedColor: $model.color)
            vSeparator
            ShapeFillModePicker(
                selectedMode: $model.shapeFillMode,
                isCircle: model.tool == .ellipse
            )
        }
    }

    private var arrowOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            HUDSlider(value: $model.lineWidth, range: 1...24, step: 1)
            vSeparator
            ColorSwatchesView(selectedColor: $model.color)
            vSeparator
            ArrowStylePicker(selectedStyle: $model.arrowStyle)
        }
    }

    private var lineOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            HUDSlider(value: $model.lineWidth, range: 1...24, step: 1)
            vSeparator
            ColorSwatchesView(selectedColor: $model.color)
        }
    }

    /// 荧光笔用的是它自己的色槽与笔尖粗细（跟画笔 / 箭头互不影响）。
    private var highlightOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            HUDSlider(
                value: $model.highlightLineWidth,
                range: Annotation.highlightWidthRange,
                step: 1
            )
            vSeparator
            ColorSwatchesView(selectedColor: $model.highlightColor)
        }
    }

    private var textOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            HUDSlider(value: $model.fontSize, range: 12...72, step: 1)
            vSeparator
            ColorSwatchesView(selectedColor: $model.color)
            vSeparator
            HUDCheckboxButton(title: "描边", isSelected: model.textHasStroke) {
                model.textHasStroke.toggle()
            }
            HUDCheckboxButton(title: "标注", isSelected: model.textHasCallout) {
                model.textHasCallout.toggle()
            }
        }
    }

    private var counterOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            HUDSlider(value: $model.lineWidth, range: 2...16, step: 1)
            vSeparator
            ColorSwatchesView(selectedColor: $model.color)
        }
    }

    private var mosaicOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("马赛克颗粒度")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.textSecondary)
            HUDSlider(
                value: model.tool == .pixelate ? $model.mosaicBlock : $model.blurRadius,
                range: 4...40,
                step: 1
            )
        }
    }

    private var eraserOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("橡皮大小")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.textSecondary)
            HUDSlider(value: $model.eraserSize, range: 8...120, step: 2)
        }
    }

    private var scrollOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "scroll")
                .font(Theme.Typography.bar)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("谁来滚")
                .font(Theme.Typography.bar)
                .foregroundStyle(Theme.Colors.textSecondary)
            scrollChoice(
                "手动滚动",
                systemImage: "hand.draw",
                help: "手动滚动：点完自己用鼠标或滚轮往下滚"
            ) {
                model.onScrollCapture?(.manual)
            }
            scrollChoice(
                "自动滚动",
                systemImage: "wand.and.rays",
                help: "自动滚动：由 Jietu 自动滚轮（需辅助功能权限）"
            ) {
                model.onScrollCapture?(.automatic)
            }
        }
    }

    private var cropOptions: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("拖拽边框调整区域")
                .font(Theme.Typography.bar)
                .foregroundStyle(Theme.Colors.textSecondary)

            vSeparator

            BarButton(chrome: .rounded, help: "完成裁剪 (↵ / 双击)") {
                model.onApplyCrop?()
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "checkmark")
                        .font(Theme.Typography.chip)
                    Text("完成裁剪")
                        .font(Theme.Typography.bar)
                }
                .foregroundStyle(Theme.Colors.success)
                .padding(.horizontal, Theme.Spacing.md)
                .frame(height: Theme.Size.barButtonHeight)
            }

            BarButton(chrome: .rounded, help: "取消裁剪 (Esc)") {
                model.onCancelCrop?()
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "xmark")
                        .font(Theme.Typography.chip)
                    Text("取消")
                        .font(Theme.Typography.bar)
                }
                .foregroundStyle(Theme.Colors.destructive)
                .padding(.horizontal, Theme.Spacing.md)
                .frame(height: Theme.Size.barButtonHeight)
            }
        }
    }

    private var vSeparator: some View {
        Rectangle()
            .fill(Theme.Colors.separator)
            .frame(width: Theme.Size.hairline, height: 16)
            .padding(.horizontal, 2)
    }

    /// 滚动截图的两个选项：图标 + 文字，点一下就用这个模式开跑。
    private func scrollChoice(
        _ title: String,
        systemImage: String,
        help: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        BarButton(chrome: .rounded, help: help, action: action) {
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
