import AppKit
import SwiftUI
import Testing
@testable import Jietu

@Suite("就地标注工具栏 — 模型")
struct InlineToolbarModelTests {
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

    @Test("主工具栏工具列表严格与 AnnotationTool.allCases 全量对齐，裁剪只给已有的图片")
    func inlineToolsAlignWithAnnotationToolCases() {
        let expected = AnnotationTool.allCases
        #expect(expected.count == 14)
        #expect(expected.first == .select)
        #expect(expected.contains(.crop))
        #expect(expected.last == .crop)

        // 第一次截图：不给裁剪——那块画面就是用户刚框出来的。
        let freshModel = InlineToolbarModel()
        #expect(!freshModel.visibleTools.contains(.crop))
        #expect(freshModel.visibleTools.count == 13)

        // 从浮窗卡片 / 钉图 / 历史记录进来编辑的已有图片：给裁剪。
        let storedModel = InlineToolbarModel()
        storedModel.allowsCrop = true
        #expect(storedModel.visibleTools == expected)

        // 渲染出来也要跟着变：少了裁剪按钮，第一次截图的工具栏更窄。
        let freshWidth = NSHostingView(rootView: InlineMainToolbar(model: freshModel))
            .fittingSize.width
        let storedWidth = NSHostingView(rootView: InlineMainToolbar(model: storedModel))
            .fittingSize.width
        #expect(freshWidth < storedWidth, "少了裁剪按钮，第一次截图的工具栏应更窄")
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

    @Test("窗口截图恢复原地编辑时按真实尺寸 1:1 展示，不再缩到屏幕比例内")
    func restoredWindowCaptureKeepsNaturalSize() {
        // 画布 1000×800、图片 1600×1200 px（= 800×600 点）：真实尺寸放得下，
        // 就该 1:1 展示（按旧的「72% 宽 / 65% 高」硬比例会被缩成 693×520）。
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: 1600,
            height: 1200,
            bitsPerComponent: 8,
            bytesPerRow: 1600 * 4,
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
        #expect(selection.width == 800, "窗口截图应按真实点尺寸展示（不缩小），实际 \(selection.width)")
        #expect(selection.height == 600, "窗口截图应按真实点尺寸展示（不缩小），实际 \(selection.height)")
        #expect(abs(selection.midX - 500) <= 1, "水平居中")
    }

    @Test("全屏截图恢复原地编辑时等比缩小以让出工具栏空间")
    func restoredFullScreenCaptureShrinksToFit() {
        // 画布 1000×800、图片 2000×1600 px（= 1000×800 点，整屏）：必然放不下，只能缩小。
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: 2000,
            height: 1600,
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
        #expect(selection.width < 1000, "整屏图必须缩小才放得下")
        #expect(selection.height <= 800 - 160, "缩小后要同时让出工具栏（下 120）与上边距（40）")
        #expect(selection.minY >= 120, "底部应预留工具栏空间")
        let ratio = selection.width / selection.height
        #expect(abs(ratio - 1000.0 / 800.0) < 0.01, "缩放应等比，不拉伸")
    }

    @Test("模糊标注：支持 8 个缩放控制点")
    func blurAnnotationHasResizeHandles() {
        let canvas = InlineEditScaffold.makeCanvas(canvas: CGSize(width: 800, height: 600))
        let blurAnnotation = Annotation(
            kind: .blur(CGRect(x: 100, y: 100, width: 200, height: 150), radius: 15),
            color: .red
        )
        let handles = canvas.inlineHandles(for: blurAnnotation)
        #expect(handles.count == 9, "未旋转的模糊标注应具有 8 个缩放控制点 + 1 个旋转控制点，实际 \(handles.count)")
        let resizeHandles = handles.filter { $0.0 != ShapeHandle.rotate }
        #expect(resizeHandles.count == 8, "应有 8 个缩放控制点")
    }

    @Test("模糊标注：工具栏模型属性变动触发回调并更新选中标注")
    func blurRadiusChangeUpdatesSelectedAnnotation() {
        let model = InlineToolbarModel()
        var radiusFired: CGFloat?
        model.onBlurRadiusChange = { radiusFired = $0 }

        model.blurRadius = 25
        #expect(radiusFired == 25, "修改 blurRadius 应当触发 onBlurRadiusChange")
    }

    @Test("标注选中时反向同步工具栏")
    func syncToolbarToAnnotationMatchesKind() {
        let canvas = InlineEditScaffold.makeCanvas(canvas: CGSize(width: 800, height: 600))
        let model = InlineToolbarModel()
        canvas.toolbarModel = model

        let blur = Annotation(kind: .blur(CGRect(x: 50, y: 50, width: 100, height: 80), radius: 28), color: .black)
        canvas.syncToolbarToAnnotation(blur)
        #expect(model.tool == .blur)
        #expect(model.blurRadius == 28)

        let pixelate = Annotation(kind: .pixelate(CGRect(x: 10, y: 10, width: 50, height: 50), block: 18), color: .black)
        canvas.syncToolbarToAnnotation(pixelate)
        #expect(model.tool == .pixelate)
        #expect(model.mosaicBlock == 18)

        let rect = Annotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 40, height: 40)), color: .blue, lineWidth: 5)
        canvas.syncToolbarToAnnotation(rect)
        #expect(model.tool == .rectangle)
        #expect(model.color == .blue)
        #expect(model.lineWidth == 5)

        let line = Annotation(kind: .line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 80)), color: .yellow, lineWidth: 7)
        canvas.syncToolbarToAnnotation(line)
        #expect(model.tool == .line)
        #expect(model.color == .yellow)
        #expect(model.lineWidth == 7)
    }

    @Test("选中已有标注：同步参数但不切换当前工具")
    func syncToolbarToAnnotationKeepsToolWhenRequested() {
        let canvas = InlineEditScaffold.makeCanvas(canvas: CGSize(width: 800, height: 600))
        let model = InlineToolbarModel()
        canvas.toolbarModel = model
        model.tool = .select

        let blur = Annotation(
            kind: .blur(CGRect(x: 50, y: 50, width: 100, height: 80), radius: 28), color: .black
        )
        canvas.syncToolbarToAnnotation(blur, updateTool: false)
        #expect(model.tool == .select, "选中已有标注不该把「选择」工具自动换掉")
        #expect(model.blurRadius == 28, "参数仍要同步到工具栏")
    }

    @Test("文本工具：点在已有标注上也能弹出输入框")
    func textToolTypesOverExistingAnnotation() {
        let region = CGRect(x: 200, y: 20, width: 600, height: 760)
        let canvas = InlineEditScaffold.makeInlineRegionCanvas(region: region)
        #expect(canvas.debugSelectTool(.text))

        // 一条盖住整个选区的模糊标注：点上去原本会被「命中已有标注」吃掉，出不来输入框。
        canvas.annotations = [
            Annotation(
                kind: .blur(CGRect(x: 0, y: 0, width: 1200, height: 1520), radius: 20),
                color: .black
            )
        ]

        let point = CGPoint(x: region.midX, y: region.midY)
        canvas.inlineMouseDown(point, clickCount: 1)
        canvas.inlineMouseUp(point)
        #expect(canvas.textField != nil, "文本工具即便点在模糊标注上，也应进入文字输入")
    }

    @Test("选择工具：拖动已选中标注的编辑框内部即可移动")
    func draggingSelectedAnnotationBoxMovesIt() {
        let region = CGRect(x: 200, y: 20, width: 600, height: 760)
        let canvas = InlineEditScaffold.makeInlineRegionCanvas(region: region)
        #expect(canvas.debugSelectTool(.select))

        // 未填充矩形：内部不算命中图形本身，过去在框内拖不动。
        let rect = Annotation(
            kind: .rectangle(CGRect(x: 100, y: 100, width: 300, height: 200)),
            color: .blue, lineWidth: 4
        )
        canvas.annotations = [rect]
        canvas.selectedID = rect.id

        // view(325,680)→crop(250,200)；view(385,720)→crop(370,120)，即整体平移 (120, -80)。
        canvas.inlineMouseDown(CGPoint(x: 325, y: 680), clickCount: 1)
        canvas.inlineMouseDragged(CGPoint(x: 385, y: 720))

        guard let moved = canvas.annotations.first else {
            Issue.record("标注不该丢失")
            return
        }
        #expect(moved.center == CGPoint(x: 370, y: 120), "框内拖动应把标注整体平移 (120, -80)")
    }

    @Test("文本工具：结束文字编辑的空白点击不再冒出新输入框")
    func textBlankClickAfterEditingDoesNotSpawnNewField() {
        let region = CGRect(x: 200, y: 20, width: 600, height: 760)
        let canvas = InlineEditScaffold.makeInlineRegionCanvas(region: region)
        #expect(canvas.debugSelectTool(.text))

        let start = CGPoint(x: region.midX, y: region.midY)
        canvas.inlineMouseDown(start, clickCount: 1)
        canvas.inlineMouseUp(start)
        #expect(canvas.textField != nil, "第一次点空白应能开始输入文字")

        let another = CGPoint(x: region.midX + 120, y: region.midY + 80)
        canvas.inlineMouseDown(another, clickCount: 1)
        canvas.inlineMouseUp(another)
        #expect(canvas.textField == nil, "刚结束编辑的空白点击只收尾，不该再冒出一个空框")
    }

    @Test("文本工具：点已有文字改字，拖动则移动")
    func textToolClicksToEditAndDragsToMove() {
        func makeCanvasWithText() -> OverlayCanvasView {
            let region = CGRect(x: 200, y: 20, width: 600, height: 760)
            let canvas = InlineEditScaffold.makeInlineRegionCanvas(region: region)
            _ = canvas.debugSelectTool(.text)
            canvas.annotations = [
                Annotation(
                    kind: .text(origin: CGPoint(x: 100, y: 100), string: "hi", fontSize: 40),
                    color: .red
                )
            ]
            return canvas
        }

        // 文字框内一点：crop(120,120) → view(260,720)。
        let inside = CGPoint(x: 260, y: 720)

        let click = makeCanvasWithText()
        click.inlineMouseDown(inside, clickCount: 1)
        click.inlineMouseUp(inside)
        #expect(click.textField != nil, "没拖动过就应该进入改字")

        let drag = makeCanvasWithText()
        drag.inlineMouseDown(inside, clickCount: 1)
        drag.inlineMouseDragged(CGPoint(x: 300, y: 700)) // crop(200,160)：平移 (80, 40)
        drag.inlineMouseUp(CGPoint(x: 300, y: 700))
        #expect(drag.textField == nil, "拖动过就不该进入改字")
        guard let moved = drag.annotations.first else {
            Issue.record("文字标注不该丢失")
            return
        }
        #expect(
            drag.textOrigin(of: moved) == CGPoint(x: 180, y: 140),
            "拖动应把文字整体平移 (80, 40)"
        )
    }

    @Test("文本工具：拖动文字编辑点改变字号")
    func textToolResizesViaHandle() {
        let region = CGRect(x: 200, y: 20, width: 600, height: 760)
        let canvas = InlineEditScaffold.makeInlineRegionCanvas(region: region)
        #expect(canvas.debugSelectTool(.text))

        let text = Annotation(
            kind: .text(origin: CGPoint(x: 200, y: 200), string: "hello", fontSize: 40),
            color: .red
        )
        canvas.annotations = [text]
        canvas.selectedID = text.id

        guard let handle = canvas.inlineHandles(for: text).first(where: { $0.0 == .bottomRight })
        else {
            Issue.record("文字框应有右下角缩放点")
            return
        }
        let start = canvas.viewPoint(fromAnnotation: handle.1)
        // 往右下方拖远（view 坐标 y 向下为负）。
        let end = CGPoint(x: start.x + 80, y: start.y - 60)
        canvas.inlineMouseDown(start, clickCount: 1)
        canvas.inlineMouseDragged(end)
        canvas.inlineMouseUp(end)

        guard case .text(_, _, let newFontSize)? = canvas.annotations.first?.kind else {
            Issue.record("文字标注丢失")
            return
        }
        #expect(newFontSize > 40, "拖编辑点应放大字号，实际 \(newFontSize)")
    }

    @Test("选中框的边：用于小手提示，内部不算边")
    func selectionBoxBorderDetection() {
        let canvas = InlineEditScaffold.makeCanvas(canvas: CGSize(width: 800, height: 600))
        let rect = Annotation(
            kind: .rectangle(CGRect(x: 100, y: 100, width: 200, height: 100)), color: .blue
        )
        #expect(canvas.inlineBoxBorderContains(rect, CGPoint(x: 100, y: 150)), "左边中点算边")
        #expect(!canvas.inlineBoxBorderContains(rect, CGPoint(x: 200, y: 150)), "正中间不算边")
        #expect(canvas.inlineBoxContains(rect, CGPoint(x: 200, y: 150)), "中间在框内")
    }

    @Test("直线标注：支持两端与中间弧度控制点且不显示多余旋转手柄")
    func lineAnnotationHasEndpointHandles() {
        let canvas = InlineEditScaffold.makeCanvas(canvas: CGSize(width: 800, height: 600))
        let from = CGPoint(x: 100, y: 100)
        let to = CGPoint(x: 300, y: 250)
        let line = Annotation(kind: .line(from: from, to: to), color: .green, lineWidth: 4)

        #expect(!line.supportsRotation, "直线自身由两端点确定朝向，不应有独立旋转手柄")

        let handles = canvas.inlineHandles(for: line)
        #expect(handles.count == 3, "直线应具有起点、终点和中间弧度控制点共 3 个手柄")

        let startHandle = handles.first { $0.0 == .lineStart }
        let endHandle = handles.first { $0.0 == .lineEnd }
        let controlHandle = handles.first { $0.0 == .lineControl }
        #expect(startHandle?.1 == from, "起点控制点坐标应严格对应 from")
        #expect(endHandle?.1 == to, "终点控制点坐标应严格对应 to")
        #expect(controlHandle?.1 == CGPoint(x: 200, y: 175), "初始直线中间手柄应位于两端中点")

        #expect(canvas.inlineHitHandle(line, at: from) == .lineStart)
        #expect(canvas.inlineHitHandle(line, at: to) == .lineEnd)
        #expect(canvas.inlineHitHandle(line, at: CGPoint(x: 200, y: 175)) == .lineControl)

        let curved = line.withEndpoint(.lineControl, to: CGPoint(x: 150, y: 100))
        let curvedHandles = canvas.inlineHandles(for: curved)
        let curvedControl = curvedHandles.first { $0.0 == .lineControl }
        #expect(curvedControl?.1 == CGPoint(x: 150, y: 100), "弯曲后中间控制点应跟踪 control 坐标")
    }
}

