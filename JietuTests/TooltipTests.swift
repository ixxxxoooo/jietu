import AppKit
import SwiftUI
import Testing
@testable import Jietu

@Suite("工具悬停提示与气泡规范")
struct TooltipTests {

    @Test("全部标注工具的中文名称符合规范")
    func annotationToolsChineseTitles() {
        #expect(AnnotationTool.select.title == "选择")
        #expect(AnnotationTool.rectangle.title == "矩形")
        #expect(AnnotationTool.ellipse.title == "椭圆")
        #expect(AnnotationTool.arrow.title == "箭头")
        #expect(AnnotationTool.line.title == "直线")
        #expect(AnnotationTool.pen.title == "画笔")
        #expect(AnnotationTool.highlight.title == "高亮笔")
        #expect(AnnotationTool.spotlight.title == "聚光灯")
        #expect(AnnotationTool.text.title == "文字")
        #expect(AnnotationTool.pixelate.title == "马赛克")
        #expect(AnnotationTool.blur.title == "模糊")
        #expect(AnnotationTool.counter.title == "序号")
        #expect(AnnotationTool.eraser.title == "橡皮")
        #expect(AnnotationTool.crop.title == "裁剪")
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
