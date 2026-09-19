import AppKit
import SwiftUI
import Testing
@testable import Jietu

@Suite("就地标注工具栏 — 裁剪")
struct OverlayCanvasCropTests {
    @Test("第一次截图的工具栏里没有裁剪，从浮窗 / 钉图进来的已有图片才有")
    func cropToolOnlyOfferedForStoredImages() {
        // 第一次截图（拖一块区域进原地编辑）：不给裁剪。
        let fresh = InlineEditScaffold.makeCanvas(canvas: CGSize(width: 1000, height: 800))
        fresh.inlineMode = true
        fresh.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150)))
        fresh.mouseDragged(with: InlineEditScaffold.mouse(.leftMouseDragged, at: NSPoint(x: 800, y: 650)))
        fresh.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 800, y: 650)))
        #expect(fresh.debugSelection != nil, "先确认进了原地编辑")
        #expect(!fresh.debugVisibleTools.contains(.crop), "第一次截图不该有裁剪工具")

        // 已有的图片（浮窗卡片 / 钉图 / 历史）：给裁剪。
        let stored = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(stored.debugVisibleTools.contains(.crop), "已有的图片才给裁剪")
    }

    @Test("裁剪：从图片中间拖出裁剪框，双击确认后按它裁掉像素")
    func cropDrawsRectFromMiddleThenApplies() {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        // 底图 1600×1200 px（2x 屏幕 → 800×600 点）居中：frame = (100, 135, 800, 600)。
        #expect(canvas.debugSelection == CGRect(x: 100, y: 135, width: 800, height: 600))
        #expect(canvas.debugSelectTool(.crop))

        // 从图片正中间往左下拖一块 200×135。
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: InlineEditScaffold.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300)))

        #expect(
            canvas.debugSelection == CGRect(x: 300, y: 300, width: 200, height: 135),
            "从中间拖出来的框就是待裁剪区域"
        )
        #expect(
            canvas.debugRestoredBase.frame == CGRect(x: 100, y: 135, width: 800, height: 600),
            "还没确认，底图先不动"
        )

        // 双击确认：按该框裁掉像素（2x → 400×270 px），底图 frame 收到裁剪框上。
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 400, y: 400), clickCount: 2))
        let base = canvas.debugRestoredBase
        #expect(base.frame == CGRect(x: 300, y: 300, width: 200, height: 135))
        #expect(base.image?.width == 400, "裁剪后宽应为选区宽 × 屏幕缩放")
        #expect(base.image?.height == 270, "裁剪后高应为选区高 × 屏幕缩放")
    }

    @Test("裁剪：框选范围锁在底图之内，拖到图外也不会超出")
    func cropRectStaysInsideBaseImage() {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))

        // 从图片中间一路拖到屏幕左下角（远在底图之外）。
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: InlineEditScaffold.mouse(.leftMouseDragged, at: NSPoint(x: 20, y: 20)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20)))

        #expect(
            canvas.debugSelection == CGRect(x: 100, y: 135, width: 400, height: 300),
            "超出底图的部分要被夹掉"
        )
    }

    @Test("裁剪：单击不毁掉已有的裁剪框")
    func cropClickKeepsPendingRect() {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))

        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: InlineEditScaffold.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300)))
        let pending = CGRect(x: 300, y: 300, width: 200, height: 135)

        // 在别处点一下（没有拖动）：框得留着。
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 700, y: 600)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 700, y: 600)))

        #expect(canvas.debugSelection == pending, "单击只是点了一下，不该把裁剪框弄没")
    }

    @Test("裁剪：拖动裁剪框时标注层贴着底图，不被压进裁剪框")
    func annotationLayerStaysGluedToBaseWhileCropping() {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))

        // 先画一笔，让标注层有内容。
        #expect(canvas.debugSelectTool(.pen))
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 300, y: 400)))
        canvas.mouseDragged(with: InlineEditScaffold.mouse(.leftMouseDragged, at: NSPoint(x: 600, y: 500)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 600, y: 500)))
        #expect(canvas.debugAnnotationCount == 1)

        #expect(canvas.debugSelectTool(.crop))
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: InlineEditScaffold.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300)))

        #expect(canvas.debugSelection == CGRect(x: 300, y: 300, width: 200, height: 135))
        #expect(
            canvas.debugAnnotationLayerFrame == CGRect(x: 100, y: 135, width: 800, height: 600),
            "标注层要贴底图；跟着裁剪框缩会把标注压扁错位"
        )
    }

    @Test("裁剪：区域截图（普通原地编辑）也能从中间框出一块来裁")
    func cropWorksForRegionScreenshots() {
        // 普通区域截图：先框一块 600×500 的区域，松手进原地标注。
        let canvas = InlineEditScaffold.makeCanvas(canvas: CGSize(width: 1000, height: 800))
        canvas.inlineMode = true
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150)))
        canvas.mouseDragged(with: InlineEditScaffold.mouse(.leftMouseDragged, at: NSPoint(x: 800, y: 650)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 800, y: 650)))
        #expect(canvas.debugSelection == CGRect(x: 200, y: 150, width: 600, height: 500))
        #expect(canvas.debugCropImageSize == CGSize(width: 1200, height: 1000), "预览底图 = 区域 × 屏幕缩放")

        // 裁剪工具：从区域中间框出 250×150。
        #expect(canvas.debugSelectTool(.crop))
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 400)))
        canvas.mouseDragged(with: InlineEditScaffold.mouse(.leftMouseDragged, at: NSPoint(x: 250, y: 250)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 250, y: 250)))
        #expect(canvas.debugSelection == CGRect(x: 250, y: 250, width: 250, height: 150))

        // 双击确认：区域收到裁剪框上，预览底图同步收小。
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 350, y: 300), clickCount: 2))
        #expect(canvas.debugSelection == CGRect(x: 250, y: 250, width: 250, height: 150))
        #expect(canvas.debugCropImageSize == CGSize(width: 500, height: 300))
    }

    @Test("裁剪：拖动裁剪框时底图整张留在画面上（框外不该露出冻结屏幕）")
    func baseImageStaysWholeWhileCropping() {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))

        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: InlineEditScaffold.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300)))

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
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))

        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 500, y: 435)))
        canvas.mouseDragged(with: InlineEditScaffold.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300)))
        #expect(canvas.debugDimHole == CGRect(x: 100, y: 135, width: 800, height: 600))

        InlineEditScaffold.confirmCrop(canvas, atPoint: CGPoint(x: 400, y: 400))
        // 确认后底图就是裁出来的这张，外框与图重合，无需再单独画一条。
        #expect(canvas.debugRestoredBase.frame == CGRect(x: 300, y: 300, width: 200, height: 135))
        #expect(canvas.debugBaseFrameBorder.isHidden, "图与外框重合时不重复画")
        #expect(canvas.debugSelection == CGRect(x: 300, y: 300, width: 200, height: 135))
    }

    @Test("裁剪：连着裁两次是在上一次的结果上继续裁（像素对得上）")
    func cropIsCumulativeOnPreviousResult() throws {
        // 渐变底图：任何偏移 / 用错基准都会在像素上露出来。
        let original = InlineEditScaffold.makeGradientImage(width: 1600, height: 1200)
        let canvas = InlineEditScaffold.makeCanvas(canvas: CGSize(width: 1000, height: 800))
        canvas.restoreImageForInlineEditing(original)
        // 底图 1600×1200 px（2x）居中：frame = (100, 135, 800, 600)。
        #expect(canvas.debugSelectTool(.crop))

        // 第 1 次：留屏幕 (200, 300, 500, 400)。
        let first = CGRect(x: 200, y: 300, width: 500, height: 400)
        InlineEditScaffold.cropDrag(canvas, to: first)
        InlineEditScaffold.confirmCrop(canvas, atPoint: CGPoint(x: 400, y: 400))

        let frame0 = CGRect(x: 100, y: 135, width: 800, height: 600)
        let firstPixels = InlineEditScaffold.pixelRect(first, in: frame0, imageOrigin: .zero, scale: 2)
        let firstBase = try #require(canvas.debugRestoredBase.image)
        #expect(canvas.debugRestoredBase.frame == first)
        #expect(
            InlineEditScaffold.samePixels(firstBase, original.cropping(to: firstPixels)),
            "第一次裁剪要正好留下原图对应的那一片"
        )

        // 第 2 次：在**上一次的结果**里再留一块 (250, 350, 300, 250)。
        #expect(canvas.debugSelectTool(.crop))
        let second = CGRect(x: 250, y: 350, width: 300, height: 250)
        InlineEditScaffold.cropDrag(canvas, to: second)
        InlineEditScaffold.confirmCrop(canvas, atPoint: CGPoint(x: 400, y: 450))

        let inner = InlineEditScaffold.pixelRect(second, in: first, imageOrigin: .zero, scale: 2)
        let expected = original.cropping(to: CGRect(
            x: firstPixels.minX + inner.minX,
            y: firstPixels.minY + inner.minY,
            width: inner.width,
            height: inner.height
        ))
        let finalBase = try #require(canvas.debugRestoredBase.image)
        #expect(finalBase.width == 600 && finalBase.height == 500)
        #expect(
            InlineEditScaffold.samePixels(finalBase, expected),
            "第二次裁剪要基于第一次的结果继续裁，而不是回到原图重新选区"
        )
    }

    @Test("裁剪：框完直接点 ✓ 也要按这个框裁，不能把没裁的原图交出去")
    func pendingCropAppliesOnConfirm() throws {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        var committed: CGImage?
        canvas.onCommitAnnotated = { image, _ in committed = image }

        #expect(canvas.debugSelectTool(.crop))
        InlineEditScaffold.cropDrag(canvas, to: CGRect(x: 300, y: 300, width: 200, height: 135))
        #expect(canvas.debugRestoredBase.image?.width == 1600, "框悬着的时候底图先不动")

        // 不点「完成裁剪」，直接点主工具栏的 ✓。
        canvas.debugConfirm()

        let final = try #require(committed)
        #expect(final.width == 400 && final.height == 270, "交出去的该是裁过的那张（2x → 400×270）")
    }

    @Test("裁剪：框完直接点保存 / 钉图，交出去的也是裁过的那张")
    func pendingCropAppliesOnSaveAndPin() throws {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))
        InlineEditScaffold.cropDrag(canvas, to: CGRect(x: 300, y: 300, width: 200, height: 135))

        let saved = try #require(canvas.debugAnnotatedImage())
        #expect(saved.width == 400 && saved.height == 270)
    }

    @Test("裁剪：框完直接退出编辑器（取消）不该被裁，原图留着")
    func cancelKeepsUncroppedImage() {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.crop))
        InlineEditScaffold.cropDrag(canvas, to: CGRect(x: 300, y: 300, width: 200, height: 135))

        // Esc：取消裁剪（不是退出编辑器）。
        canvas.keyDown(with: InlineEditScaffold.key(53))
        #expect(canvas.debugRestoredBase.frame == CGRect(x: 100, y: 135, width: 800, height: 600))
        #expect(canvas.debugRestoredBase.image?.width == 1600, "取消裁剪后底图要还原")
    }
}
