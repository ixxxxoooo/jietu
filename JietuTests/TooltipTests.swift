import AppKit
import SwiftUI
import Testing
@testable import Jietu

@Suite("工具悬停提示与气泡规范")
struct TooltipTests {

    @Test("每个标注工具的名称都取自自己的 L10n 键")
    func annotationToolsChineseTitles() {
        // 对照 L10n 而不是写死中文：写死的话换到英文环境会整片红（CI 就是英文）。
        // 这样仍能抓住「工具接错了文案键」这类问题。
        #expect(AnnotationTool.select.title == L10n.toolSelect)
        #expect(AnnotationTool.rectangle.title == L10n.toolRectangle)
        #expect(AnnotationTool.ellipse.title == L10n.toolEllipse)
        #expect(AnnotationTool.arrow.title == L10n.toolArrow)
        #expect(AnnotationTool.line.title == L10n.toolLine)
        #expect(AnnotationTool.pen.title == L10n.toolPen)
        #expect(AnnotationTool.highlight.title == L10n.toolHighlight)
        #expect(AnnotationTool.spotlight.title == L10n.toolSpotlight)
        #expect(AnnotationTool.text.title == L10n.toolText)
        #expect(AnnotationTool.pixelate.title == L10n.toolPixelate)
        #expect(AnnotationTool.blur.title == L10n.toolBlur)
        #expect(AnnotationTool.counter.title == L10n.toolCounter)
        #expect(AnnotationTool.eraser.title == L10n.toolEraser)
        #expect(AnnotationTool.crop.title == L10n.toolCrop)
    }

    @Test("TooltipView 视图渲染及非侵入性")
    func tooltipViewRenders() {
        let tooltip = TooltipView(text: "矩形")
        let host = NSHostingView(rootView: tooltip)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test("BarButton 挂载提示文本与朝向")
    func barButtonWithTooltip() {
        let button = BarButton(
            chrome: .rounded,
            isSelected: false,
            help: "矩形",
            tooltipPlacement: .top,
            action: {}
        ) {
            Image(systemName: "rectangle")
        }

        let host = NSHostingView(rootView: button)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test("就地工具栏主栏完整渲染，挂载提示后尺寸正常稳定")
    func inlineMainToolbarRendersWithTooltips() {
        let model = InlineToolbarModel()
        let host = NSHostingView(rootView: InlineMainToolbar(model: model))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        #expect(size.width > 300)
        #expect(size.height > 20)
    }

    @Test("提示延迟常量配置合理（初始延迟在 0.3s~0.6s 之间，连续延迟 <= 0.1s）")
    func tooltipDelayDurationConfig() {
        #expect(Theme.Duration.tooltipDelay >= 0.3 && Theme.Duration.tooltipDelay <= 0.6)
        #expect(Theme.Duration.tooltipReshowDelay <= 0.1)
    }

    @Test("TooltipTracker 连续悬停状态判定")
    @MainActor
    func tooltipTrackerState() {
        let tracker = TooltipTracker.shared
        tracker.notifyVisible()
        #expect(tracker.isContinuouslyHovering)
        tracker.notifyHidden()
        #expect(tracker.isContinuouslyHovering)
    }
}
