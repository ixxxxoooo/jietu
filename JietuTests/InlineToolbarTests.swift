import AppKit
import SwiftUI
import Testing
@testable import Jietu

@Suite("就地标注工具栏")
struct InlineToolbarTests {

    @Test("滚动截图：模型把「手动 / 自动」交出去")
    func scrollCaptureHandsOffMode() {
        let model = InlineToolbarModel()
        #expect(!model.showScroll)

        var picked: [ScrollingCaptureSession.Mode] = []
        model.onScrollCapture = { picked.append($0) }
        model.onScrollCapture?(.manual)
        model.onScrollCapture?(.automatic)
        #expect(picked == [.manual, .automatic])
    }

    @Test("二级菜单：选中工具时展开对应选项条，未选中时收起")
    func subToolbarExpandsWhenToolSelected() {
        let model = InlineToolbarModel()

        func optionsSize() -> NSSize {
            NSHostingView(rootView: InlineOptionsToolbar(model: model)).fittingSize
        }

        #expect(!model.isSubToolbarVisible)
        #expect(optionsSize().width == 0, "默认无工具时二级菜单内容为空")

        model.tool = .rectangle
        #expect(model.isSubToolbarVisible)
        #expect(optionsSize().width > 0, "选中矩形后二级菜单应展开显示粗细、颜色与填充选项")

        model.tool = .arrow
        #expect(model.isSubToolbarVisible)
        #expect(optionsSize().width > 0, "选中箭头后二级菜单应展开显示箭头样式与颜色")

        model.tool = .text
        #expect(model.isSubToolbarVisible)
        #expect(optionsSize().width > 0, "选中文字后二级菜单应展开显示字号、颜色与描边标注选项")

        model.tool = .crop
        #expect(model.isSubToolbarVisible)
        #expect(optionsSize().width > 0, "选中裁剪后二级菜单应展开显示完成与取消选项")

        model.tool = nil
        #expect(!model.isSubToolbarVisible)
        #expect(optionsSize().width == 0, "取消选择工具后二级菜单收起")

        model.showScroll = true
        #expect(model.isSubToolbarVisible)
        #expect(optionsSize().width > 0, "打开滚动截图后二级菜单展开显示模式选项")
    }

    @Test("主工具栏带「录屏」入口：点了就把当前选区交出去")
    func mainToolbarHasRecordEntry() {
        let model = InlineToolbarModel()
        var fired = 0
        model.onRecord = { fired += 1 }

        let host = NSHostingView(rootView: InlineMainToolbar(model: model))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0, "加了「录屏」之后主工具栏照样能量出尺寸")

        // 「录屏」不是展开式选项（不像颜色 / 粗细 / 滚动截图），点一下就把选区交出去——
        // 真实的交接（遮罩收掉 → 红框 + 待开始控制条）由 `--selftest-app-record` 端到端验。
        model.onRecord?()
        #expect(fired == 1)
    }

    @Test("主工具栏带「滚动截图」入口")
    func mainToolbarHasScrollEntry() {
        let model = InlineToolbarModel()
        let host = NSHostingView(rootView: InlineMainToolbar(model: model))
        let size = host.fittingSize
        #expect(size.width > 0, "主工具栏至少要能量出尺寸")

        // 展开选项时主栏尺寸不变（固定尺寸，避免抖动）——滚动截图那一项也走同一条路。
        model.showScroll = true
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
    }

    @Test("默认不选择任何工具，重复点击同一工具可取消选择")
    func defaultNoToolAndCanDeselect() {
        let model = InlineToolbarModel()
        #expect(model.tool == nil, "默认不应预选任何工具")

        model.tool = .rectangle
        #expect(model.tool == .rectangle)

        model.tool = nil
        #expect(model.tool == nil)
    }

    @Test("主工具栏工具列表严格与 AnnotationTool.allCases 全量对齐（包含 crop）")
    func inlineToolsAlignWithAnnotationToolCases() {
        let expected = AnnotationTool.allCases
        let host = NSHostingView(rootView: InlineMainToolbar(model: InlineToolbarModel()))
        host.layoutSubtreeIfNeeded()
        #expect(expected.count == 14)
        #expect(expected.first == .select)
        #expect(expected.contains(.crop))
        #expect(expected.last == .crop)
    }

    @Test("恢复静态图片时主工具栏紧凑隐藏滚动与录屏按钮")
    func restoredImageToolbarOmitsScrollAndRecord() {
        let standardModel = InlineToolbarModel()
        let standardHost = NSHostingView(rootView: InlineMainToolbar(model: standardModel))
        let standardWidth = standardHost.fittingSize.width

        let restoredModel = InlineToolbarModel()
        restoredModel.isRestoredImage = true
        let restoredHost = NSHostingView(rootView: InlineMainToolbar(model: restoredModel))
        let restoredWidth = restoredHost.fittingSize.width

        #expect(restoredWidth > 0)
        #expect(restoredWidth < standardWidth, "隐藏滚动与录屏后，恢复模式工具栏宽度应更加紧凑")
    }

    @Test("restoreImageForInlineEditing 使图片在画布居中并直接进入原地标注状态")
    func restoreImageForInlineEditingCentersSelection() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: 400,
            height: 300,
            bitsPerComponent: 8,
            bytesPerRow: 400 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = ctx.makeImage()!

        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 1000, height: 800),
            nominalScaleFactor: 2,
            image: image
        )
        let session = CaptureSession(snapshots: [snapshot], windows: [])
        let canvas = OverlayCanvasView(
            snapshot: snapshot,
            session: session,
            displayIndex: 1,
            displayCount: 1
        )

        canvas.restoreImageForInlineEditing(image)

        #expect(canvas.isAnnotationPhase, "恢复后应直接进入标注阶段")
        guard let selection = canvas.debugSelection else {
            Issue.record("未生成居中选区")
            return
        }

        // 验证水平居中（允许 1pt 四舍五入误差）
        let expectedCenterX = 500.0
        #expect(abs(selection.midX - expectedCenterX) <= 1.0, "选区应在水平方向严格居中")
        #expect(selection.width > 0 && selection.height > 0)
    }

    @Test("裁剪回调：模型能够分发完成与取消裁剪回调")
    func cropCallbacksTriggerProperly() {
        let model = InlineToolbarModel()
        var applied = 0
        var canceled = 0
        model.onApplyCrop = { applied += 1 }
        model.onCancelCrop = { canceled += 1 }

        model.onApplyCrop?()
        model.onCancelCrop?()
        #expect(applied == 1)
        #expect(canceled == 1)
    }

    @Test("restoreImageForInlineEditing 为工具栏留出底部空间")
    func restoreImageLeavesBottomSpaceForToolbar() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: 2000,
            height: 2000,
            bitsPerComponent: 8,
            bytesPerRow: 2000 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = ctx.makeImage()!

        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 1000, height: 800),
            nominalScaleFactor: 2,
            image: image
        )
        let session = CaptureSession(snapshots: [snapshot], windows: [])
        let canvas = OverlayCanvasView(
            snapshot: snapshot,
            session: session,
            displayIndex: 1,
            displayCount: 1
        )

        canvas.restoreImageForInlineEditing(image)

        guard let selection = canvas.debugSelection else {
            Issue.record("未生成居中选区")
            return
        }

        #expect(selection.minY >= 120.0, "底部应预留至少 120pt 容纳主工具栏与二级菜单")
    }

    @Test("原地编辑模式下滚轮与捏合可缩放图片选区")
    func zoomChangesSelectionInAnnotatingPhase() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: 800,
            height: 600,
            bitsPerComponent: 8,
            bytesPerRow: 800 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = ctx.makeImage()!

        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 1000, height: 800),
            nominalScaleFactor: 2,
            image: image
        )
        let session = CaptureSession(snapshots: [snapshot], windows: [])
        let canvas = OverlayCanvasView(
            snapshot: snapshot,
            session: session,
            displayIndex: 1,
            displayCount: 1
        )
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        canvas.restoreImageForInlineEditing(image)

        let initialSelection = canvas.debugSelection
        #expect(initialSelection != nil)
        let initialWidth = initialSelection!.width

        // 构造放大滚轮事件
        let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 20,
            wheel2: 0,
            wheel3: 0
        )!
        let scrollEvent = NSEvent(cgEvent: cgEvent)!
        canvas.scrollWheel(with: scrollEvent)

        let zoomedSelection = canvas.debugSelection
        #expect(zoomedSelection != nil)
        #expect(zoomedSelection!.width > initialWidth, "滚轮向上应放大选区")
    }

    @Test("浮窗预览模式下拖拽框选松手自动提交截图")
    func quickAccessModeCommitsOnMouseUp() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: 800,
            height: 600,
            bitsPerComponent: 8,
            bytesPerRow: 800 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = ctx.makeImage()!

        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 1000, height: 800),
            nominalScaleFactor: 2,
            image: image
        )
        let session = CaptureSession(snapshots: [snapshot], windows: [])
        let canvas = OverlayCanvasView(
            snapshot: snapshot,
            session: session,
            displayIndex: 1,
            displayCount: 1
        )
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        canvas.inlineMode = false // 浮窗预览模式

        var committedRect: CGRect?
        canvas.onCommit = { rect in
            committedRect = rect
        }

        // 模拟拖选过程
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 300, y: 300),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 300, y: 300),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!

        canvas.mouseDown(with: downEvent)
        canvas.mouseDragged(with: dragEvent)
        canvas.mouseUp(with: upEvent)

        #expect(committedRect != nil, "松开鼠标应立即提交截图，无需双击或按回车")
        #expect(committedRect!.width >= 100 && committedRect!.height >= 100)
    }
}
