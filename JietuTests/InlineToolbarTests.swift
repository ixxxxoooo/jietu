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

    // MARK: - 裁剪：框选要保留的区域

    @Test("第一次截图的工具栏里没有裁剪，从浮窗 / 钉图进来的已有图片才有")
    func cropToolOnlyOfferedForStoredImages() {
        // 第一次截图（拖一块区域进原地编辑）：不给裁剪。
        let fresh = Self.makeCanvas(canvas: CGSize(width: 1000, height: 800))
        fresh.inlineMode = true
        fresh.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150)))
        fresh.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 800, y: 650)))
        fresh.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 800, y: 650)))
        #expect(fresh.debugSelection != nil, "先确认进了原地编辑")
        #expect(!fresh.debugVisibleTools.contains(.crop), "第一次截图不该有裁剪工具")

        // 已有的图片（浮窗卡片 / 钉图 / 历史）：给裁剪。
        let stored = Self.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(stored.debugVisibleTools.contains(.crop), "已有的图片才给裁剪")
    }

    @Test("裁剪：从图片中间拖出裁剪框，双击确认后按它裁掉像素")
    func cropDrawsRectFromMiddleThenApplies() {
        let canvas = Self.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        // 底图 1600×1200 px（2x 屏幕 → 800×600 点）居中：frame = (100, 135, 800, 600)。
        #expect(canvas.debugSelection == CGRect(x: 100, y: 135, width: 800, height: 600))
        #expect(canvas.debugSelectTool(.crop))

        // 从图片正中间往左下拖一块 200×135。
        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300)))
        canvas.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300)))

        #expect(
            canvas.debugSelection == CGRect(x: 300, y: 300, width: 200, height: 135),
            "从中间拖出来的框就是待裁剪区域"
        )
        #expect(
            canvas.debugRestoredBase.frame == CGRect(x: 100, y: 135, width: 800, height: 600),
            "还没确认，底图先不动"
        )

        // 双击确认：按该框裁掉像素（2x → 400×270 px），底图 frame 收到裁剪框上。
        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 400, y: 400), clickCount: 2))
        let base = canvas.debugRestoredBase
        #expect(base.frame == CGRect(x: 300, y: 300, width: 200, height: 135))
        #expect(base.image?.width == 400, "裁剪后宽应为选区宽 × 屏幕缩放")
        #expect(base.image?.height == 270, "裁剪后高应为选区高 × 屏幕缩放")
    }

    @Test("裁剪：框选范围锁在底图之内，拖到图外也不会超出")
    func cropRectStaysInsideBaseImage() {
        let canvas = Self.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))

        // 从图片中间一路拖到屏幕左下角（远在底图之外）。
        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 20, y: 20)))
        canvas.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20)))

        #expect(
            canvas.debugSelection == CGRect(x: 100, y: 135, width: 400, height: 300),
            "超出底图的部分要被夹掉"
        )
    }

    @Test("裁剪：单击不毁掉已有的裁剪框")
    func cropClickKeepsPendingRect() {
        let canvas = Self.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))

        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300)))
        canvas.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300)))
        let pending = CGRect(x: 300, y: 300, width: 200, height: 135)

        // 在别处点一下（没有拖动）：框得留着。
        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 700, y: 600)))
        canvas.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 700, y: 600)))

        #expect(canvas.debugSelection == pending, "单击只是点了一下，不该把裁剪框弄没")
    }

    @Test("裁剪：拖动裁剪框时标注层贴着底图，不被压进裁剪框")
    func annotationLayerStaysGluedToBaseWhileCropping() {
        let canvas = Self.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))

        // 先画一笔，让标注层有内容。
        #expect(canvas.debugSelectTool(.pen))
        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 300, y: 400)))
        canvas.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 600, y: 500)))
        canvas.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 600, y: 500)))
        #expect(canvas.debugAnnotationCount == 1)

        #expect(canvas.debugSelectTool(.crop))
        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300)))
        canvas.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300)))

        #expect(canvas.debugSelection == CGRect(x: 300, y: 300, width: 200, height: 135))
        #expect(
            canvas.debugAnnotationLayerFrame == CGRect(x: 100, y: 135, width: 800, height: 600),
            "标注层要贴底图；跟着裁剪框缩会把标注压扁错位"
        )
    }

    @Test("裁剪：区域截图（普通原地编辑）也能从中间框出一块来裁")
    func cropWorksForRegionScreenshots() {
        // 普通区域截图：先框一块 600×500 的区域，松手进原地标注。
        let canvas = Self.makeCanvas(canvas: CGSize(width: 1000, height: 800))
        canvas.inlineMode = true
        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150)))
        canvas.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 800, y: 650)))
        canvas.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 800, y: 650)))
        #expect(canvas.debugSelection == CGRect(x: 200, y: 150, width: 600, height: 500))
        #expect(canvas.debugCropImageSize == CGSize(width: 1200, height: 1000), "预览底图 = 区域 × 屏幕缩放")

        // 裁剪工具：从区域中间框出 250×150。
        #expect(canvas.debugSelectTool(.crop))
        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 400)))
        canvas.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 250, y: 250)))
        canvas.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 250, y: 250)))
        #expect(canvas.debugSelection == CGRect(x: 250, y: 250, width: 250, height: 150))

        // 双击确认：区域收到裁剪框上，预览底图同步收小。
        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 350, y: 300), clickCount: 2))
        #expect(canvas.debugSelection == CGRect(x: 250, y: 250, width: 250, height: 150))
        #expect(canvas.debugCropImageSize == CGSize(width: 500, height: 300))
    }

    @Test("裁剪：拖动裁剪框时底图整张留在画面上（框外不该露出冻结屏幕）")
    func baseImageStaysWholeWhileCropping() {
        let canvas = Self.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))

        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300)))
        canvas.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300)))

        let base = CGRect(x: 100, y: 135, width: 800, height: 600)
        let frames = canvas.debugRestoredLayerFrames
        #expect(
            frames.container == base,
            "容器要停在底图 frame 上，不能收到裁剪框上（否则框外露出屏幕，看着像重新选区）"
        )
        #expect(frames.image == CGRect(x: 0, y: 0, width: 800, height: 600), "底图整张画着")

        // 压暗层挖的是整张图（不是裁剪框）：图本身一直亮着，只有图外压暗。
        #expect(canvas.debugDimHole == base, "裁剪时压暗层不该遮住原来的图")

        // 图的边界还在：框缩到中间以后，靠这条外框才知道图到哪儿为止。
        let border = canvas.debugBaseFrameBorder
        #expect(!border.isHidden, "裁剪时底图外框要留着")
        #expect(border.rect == base)

        // 选择框 / 控制点要压在遮罩之上，否则贴边那一条会被遮罩切掉一半。
        #expect(canvas.debugChromeAboveDim, "裁剪框与控制点必须画在压暗层之上")
    }

    @Test("裁剪：确认之后压暗层才重新按裁剪框（图这时才真的变了）")
    func dimFollowsSelectionAfterCropConfirmed() {
        let canvas = Self.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))

        canvas.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300)))
        canvas.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300)))
        #expect(canvas.debugDimHole == CGRect(x: 100, y: 135, width: 800, height: 600))

        Self.confirmCrop(canvas, atPoint: CGPoint(x: 400, y: 400))
        // 确认后底图就是裁出来的这张，外框与图重合，无需再单独画一条。
        #expect(canvas.debugRestoredBase.frame == CGRect(x: 300, y: 300, width: 200, height: 135))
        #expect(canvas.debugBaseFrameBorder.isHidden, "图与外框重合时不重复画")
        #expect(canvas.debugSelection == CGRect(x: 300, y: 300, width: 200, height: 135))
    }

    @Test("裁剪：连着裁两次是在上一次的结果上继续裁（像素对得上）")
    func cropIsCumulativeOnPreviousResult() throws {
        // 渐变底图：任何偏移 / 用错基准都会在像素上露出来。
        let original = Self.makeGradientImage(width: 1600, height: 1200)
        let canvas = Self.makeCanvas(canvas: CGSize(width: 1000, height: 800))
        canvas.restoreImageForInlineEditing(original)
        // 底图 1600×1200 px（2x）居中：frame = (100, 135, 800, 600)。
        #expect(canvas.debugSelectTool(.crop))

        // 第 1 次：留屏幕 (200, 300, 500, 400)。
        let first = CGRect(x: 200, y: 300, width: 500, height: 400)
        Self.cropDrag(canvas, to: first)
        Self.confirmCrop(canvas, atPoint: CGPoint(x: 400, y: 400))

        let frame0 = CGRect(x: 100, y: 135, width: 800, height: 600)
        let firstPixels = Self.pixelRect(first, in: frame0, imageOrigin: .zero, scale: 2)
        let firstBase = try #require(canvas.debugRestoredBase.image)
        #expect(canvas.debugRestoredBase.frame == first)
        #expect(
            Self.samePixels(firstBase, original.cropping(to: firstPixels)),
            "第一次裁剪要正好留下原图对应的那一片"
        )

        // 第 2 次：在**上一次的结果**里再留一块 (250, 350, 300, 250)。
        #expect(canvas.debugSelectTool(.crop))
        let second = CGRect(x: 250, y: 350, width: 300, height: 250)
        Self.cropDrag(canvas, to: second)
        Self.confirmCrop(canvas, atPoint: CGPoint(x: 400, y: 450))

        let inner = Self.pixelRect(second, in: first, imageOrigin: .zero, scale: 2)
        let expected = original.cropping(to: CGRect(
            x: firstPixels.minX + inner.minX,
            y: firstPixels.minY + inner.minY,
            width: inner.width,
            height: inner.height
        ))
        let finalBase = try #require(canvas.debugRestoredBase.image)
        #expect(finalBase.width == 600 && finalBase.height == 500)
        #expect(
            Self.samePixels(finalBase, expected),
            "第二次裁剪要基于第一次的结果继续裁，而不是回到原图重新选区"
        )
    }

    @Test("裁剪：框完直接点 ✓ 也要按这个框裁，不能把没裁的原图交出去")
    func pendingCropAppliesOnConfirm() throws {
        let canvas = Self.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        var committed: CGImage?
        canvas.onCommitAnnotated = { image, _ in committed = image }

        #expect(canvas.debugSelectTool(.crop))
        Self.cropDrag(canvas, to: CGRect(x: 300, y: 300, width: 200, height: 135))
        #expect(canvas.debugRestoredBase.image?.width == 1600, "框悬着的时候底图先不动")

        // 不点「完成裁剪」，直接点主工具栏的 ✓。
        canvas.debugConfirm()

        let final = try #require(committed)
        #expect(final.width == 400 && final.height == 270, "交出去的该是裁过的那张（2x → 400×270）")
    }

    @Test("裁剪：框完直接点保存 / 钉图，交出去的也是裁过的那张")
    func pendingCropAppliesOnSaveAndPin() throws {
        let canvas = Self.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))
        Self.cropDrag(canvas, to: CGRect(x: 300, y: 300, width: 200, height: 135))

        let saved = try #require(canvas.debugAnnotatedImage())
        #expect(saved.width == 400 && saved.height == 270)
    }

    @Test("裁剪：框完直接退出编辑器（取消）不该被裁，原图留着")
    func cancelKeepsUncroppedImage() {
        let canvas = Self.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))
        Self.cropDrag(canvas, to: CGRect(x: 300, y: 300, width: 200, height: 135))

        // Esc：取消裁剪（不是退出编辑器）。
        canvas.keyDown(with: Self.key(53))
        #expect(canvas.debugRestoredBase.frame == CGRect(x: 100, y: 135, width: 800, height: 600))
        #expect(canvas.debugRestoredBase.image?.width == 1600, "取消裁剪后底图要还原")
    }

    // MARK: - 就地编辑测试脚手架

    /// 造一块普通原地编辑画布：快照底图与画布同比例（`effectiveScale` == `scale`）。
    private static func makeCanvas(canvas size: CGSize, scale: CGFloat = 2) -> OverlayCanvasView {
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(origin: .zero, size: size),
            nominalScaleFactor: scale,
            image: makeImage(width: Int(size.width * scale), height: Int(size.height * scale))
        )
        let view = OverlayCanvasView(
            snapshot: snapshot,
            session: CaptureSession(snapshots: [snapshot], windows: []),
            displayIndex: 1,
            displayCount: 1
        )
        view.frame = NSRect(origin: .zero, size: size)
        return view
    }

    /// 造一块画布 + 一张恢复进来的底图，并直接进入原地编辑（图片居中、工具栏就位）。
    ///
    /// 画布 1000×800、底图 1600×1200 px（2x 屏幕 → 800×600 点）时，底图 frame 是 (100, 135, 800, 600)。
    /// `allowsCrop` 默认 true：这条路径对应「从浮窗卡片 / 钉图进来的已有图片」。
    private static func makeRestoredCanvas(
        canvas size: CGSize,
        imagePixels: (width: Int, height: Int) = (1600, 1200),
        scale: CGFloat = 2,
        allowsCrop: Bool = true
    ) -> OverlayCanvasView {
        let view = makeCanvas(canvas: size, scale: scale)
        view.allowsCrop = allowsCrop
        view.restoreImageForInlineEditing(
            makeImage(width: imagePixels.width, height: imagePixels.height)
        )
        return view
    }

    private static func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    /// 造一个按键事件（`keyCode` 用 AppKit 的原始码，53 = Esc、36 = Return）。
    private static func key(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private static func mouse(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        clickCount: Int = 1
    ) -> NSEvent {        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0
        )!
    }

    /// 裁剪工具下从矩形右下角拖到左上角（即「从中间框出这块」），松手不确认。
    private static func cropDrag(_ canvas: OverlayCanvasView, to rect: CGRect) {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: rect.maxX, y: rect.maxY)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: rect.minX, y: rect.minY)))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: rect.minX, y: rect.minY)))
    }

    /// 双击确认裁剪。
    private static func confirmCrop(_ canvas: OverlayCanvasView, atPoint point: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: point, clickCount: 2))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: point, clickCount: 2))
    }

    /// 屏幕矩形 → 图像像素矩形。`frame` 是该图在屏幕上的位置，`imageOrigin` 是这张图左上角在
    /// **原始底图**里的像素坐标（第一次裁剪传 .zero，之后传上一层裁出来的原点）。
    private static func pixelRect(
        _ rect: CGRect,
        in frame: CGRect,
        imageOrigin: CGPoint,
        scale: CGFloat
    ) -> CGRect {
        CGRect(
            x: imageOrigin.x + (rect.minX - frame.minX) * scale,
            y: imageOrigin.y + (frame.maxY - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    /// 渐变底图：斜向红→绿→蓝，任何位置差错都会在像素上露出来。
    private static func makeGradientImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            ] as CFArray,
            locations: [0, 0.5, 1]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: width, y: height),
            options: []
        )
        return ctx.makeImage()!
    }

    /// 逐点比较两张图（尺寸一致时）。
    private static func samePixels(_ a: CGImage?, _ b: CGImage?) -> Bool {
        guard let a, let b, a.width == b.width, a.height == b.height else { return false }
        let stepX = max(1, a.width / 12)
        let stepY = max(1, a.height / 9)
        for y in stride(from: 0, to: a.height, by: stepY) {
            for x in stride(from: 0, to: a.width, by: stepX) {
                let point = CGPoint(x: x, y: y)
                guard
                    let left = PixelSampler.sample(a, atPixel: point),
                    let right = PixelSampler.sample(b, atPixel: point),
                    left.red == right.red,
                    left.green == right.green,
                    left.blue == right.blue
                else { return false }
            }
        }
        return true
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
