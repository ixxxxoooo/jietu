import AppKit
import SwiftUI
import Testing
@testable import Jietu

@Suite("就地标注工具栏 — 摆放与文字样式")
struct ToolbarPlacementTests {

    @Test("主工具栏能竖排：竖排更窄更高（横排摆不下时靠它停到左右侧）")
    func mainToolbarSupportsVerticalLayout() {
        let model = InlineToolbarModel()
        let host = NSHostingView(rootView: InlineMainToolbar(model: model))
        host.layoutSubtreeIfNeeded()
        let horizontal = host.fittingSize

        model.isVerticalLayout = true
        host.layoutSubtreeIfNeeded()
        let vertical = host.fittingSize

        #expect(horizontal.width > horizontal.height, "横排本该是宽的")
        #expect(vertical.width < horizontal.width, "竖排更窄")
        #expect(vertical.height > horizontal.height, "竖排更高")
    }

    @Test("二级菜单也能竖排：竖排时更窄更高")
    func optionsToolbarSupportsVerticalLayout() {
        let model = InlineToolbarModel()
        model.tool = .text
        let host = NSHostingView(rootView: InlineOptionsToolbar(model: model))
        host.layoutSubtreeIfNeeded()
        let horizontal = host.fittingSize

        model.isVerticalLayout = true
        host.layoutSubtreeIfNeeded()
        let vertical = host.fittingSize

        #expect(horizontal.width > horizontal.height, "横排本该是宽的一条")
        #expect(vertical.width < horizontal.width, "竖排更窄")
        #expect(vertical.height > horizontal.height, "竖排更高")
    }

    @Test("工具栏摆放：竖排时二级菜单也竖着贴在主栏旁边")
    func optionsToolbarSitsBesideVerticalMainBar() async throws {
        // 贴屏幕底部、靠左的选区：下面没位置，右侧有足够位置摆「主栏 + 二级菜单」这一列。
        let canvas = InlineEditScaffold.makeInlineRegionCanvas(region: CGRect(x: 20, y: 20, width: 300, height: 200))
        #expect(canvas.debugSelectTool(.text))
        // 二级菜单是随光标工具变化之后（下一个主队列周期）才重排的，等它跑完。
        await InlineEditScaffold.drainMainQueue()

        let layout = canvas.debugToolbarLayout
        #expect(layout.isVertical, "主栏竖排")
        let options = try #require(layout.options)
        #expect(
            abs(options.minX - (layout.main.maxX + 10)) <= 1,
            "二级菜单要竖着贴在主栏外侧（主栏 maxX=\(layout.main.maxX) → 二级 minX≈\(layout.main.maxX + 10)）"
        )
        #expect(
            abs(options.midY - layout.main.midY) <= 1,
            "与主栏上下居中（主栏 midY=\(layout.main.midY)，二级 midY=\(options.midY)）"
        )
    }

    @Test("滑块 / 色板竖排：自己也竖过来（滑块变高、色板变一列）")
    func controlsTurnVerticalToo() {
        let slider = HUDSlider(value: .constant(7), range: 1...24)
        let verticalSlider = HUDSlider(value: .constant(7), range: 1...24, isVertical: true)
        let sliderHost = NSHostingView(rootView: slider)
        let verticalHost = NSHostingView(rootView: verticalSlider)
        sliderHost.layoutSubtreeIfNeeded()
        verticalHost.layoutSubtreeIfNeeded()
        #expect(sliderHost.fittingSize.width > sliderHost.fittingSize.height, "横排滑块是横的")
        #expect(verticalHost.fittingSize.height > verticalHost.fittingSize.width, "竖排滑块要立起来")

        let palette = NSHostingView(
            rootView: ColorSwatchesView(selectedColor: .constant(.red))
        )
        let verticalPalette = NSHostingView(
            rootView: ColorSwatchesView(selectedColor: .constant(.red), isVertical: true)
        )
        palette.layoutSubtreeIfNeeded()
        verticalPalette.layoutSubtreeIfNeeded()
        #expect(palette.fittingSize.width > palette.fittingSize.height, "横排色板是一行")
        #expect(
            verticalPalette.fittingSize.height > verticalPalette.fittingSize.width,
            "竖排色板要变成一列"
        )
    }

    @Test("马赛克 / 橡皮的二级菜单里只剩滑块，没有文字标签")
    func mosaicAndEraserOptionsHaveNoLabel() {
        // 竖排的宽度就是「最宽那一行」的宽度：只剩一条立起来的滑块时应当很窄，
        // 以前那行「马赛克颗粒度」文字会把它撑到 100pt 以上。
        for tool in [AnnotationTool.pixelate, .blur, .eraser] {
            let model = InlineToolbarModel()
            model.tool = tool
            model.isVerticalLayout = true
            let host = NSHostingView(rootView: InlineOptionsToolbar(model: model))
            host.layoutSubtreeIfNeeded()
            #expect(
                host.fittingSize.width <= 60,
                "\(tool.title) 的竖排面板应当只剩一条滑块，实际宽度 \(host.fittingSize.width)"
            )
        }
    }

    @Test("二级菜单竖排时整体是窄窄一条")
    func verticalOptionsToolbarIsNarrow() {
        let model = InlineToolbarModel()
        model.tool = .rectangle
        let host = NSHostingView(rootView: InlineOptionsToolbar(model: model))
        model.isVerticalLayout = true
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 90, "竖排的二级菜单应当是窄窄一条，实际 \(host.fittingSize.width)")
        #expect(host.fittingSize.height > host.fittingSize.width)
    }

    @Test("工具栏摆放：下面放得下就横排贴在选区下面")
    func toolbarDocksBelowWhenThereIsRoom() {
        // 图 600×400 px → 300×200 点居中（选区下方还有 ~330pt）。
        let canvas = InlineEditScaffold.makeRestoredCanvas(
            canvas: CGSize(width: 1000, height: 800),
            imagePixels: (width: 600, height: 400)
        )
        let layout = canvas.debugToolbarLayout
        #expect(!layout.isVertical, "下面放得下就不该竖排")
        #expect(layout.main.maxY <= 335, "贴在选区（minY=335）下面")
        #expect(abs(layout.main.midX - canvas.debugSelection!.midX) <= 1, "与选区水平对齐")
    }

    @Test("工具栏摆放：下面放不下就竖排停到右侧；两侧都没位置才退回上方")
    func toolbarDocksToTheSideWhenNoRoomBelow() {
        // 贴屏幕底部的窄选区：下面没位置，左右各有位置 → 停右侧、竖排。
        let side = InlineEditScaffold.makeInlineRegionCanvas(region: CGRect(x: 200, y: 20, width: 600, height: 200))
        let layout = side.debugToolbarLayout
        #expect(layout.isVertical, "下面放不下就该竖排")
        #expect(
            abs(layout.main.minX - (side.debugSelection!.maxX + 10)) <= 1,
            "要**贴着选区**右侧摆（选区 maxX=800 → 工具栏 minX≈810），不是贴到屏幕边上去"
        )

        // 横跨整屏的选区：左右也塞不下 → 退回选区上方。
        let wide = InlineEditScaffold.makeInlineRegionCanvas(region: CGRect(x: 20, y: 20, width: 960, height: 200))
        let wideLayout = wide.debugToolbarLayout
        #expect(!wideLayout.isVertical, "两侧都没位置就别硬竖排")
        #expect(wideLayout.main.minY > 220, "退回选区上方")
    }

    @Test("文字：选中之后切「描边 / 标注」，当场刷到这条文字上")
    func textStyleAppliesToSelectedTextImmediately() async throws {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        let id = try #require(canvas.debugInsertText("标注", atViewPoint: CGPoint(x: 300, y: 400)))
        #expect(canvas.debugSelectedID == id)
        #expect(canvas.debugAnnotation(id)?.textHasStroke == false)

        #expect(canvas.debugSelectTool(.text))
        canvas.debugSetTextStyle(hasStroke: true, hasCallout: true)

        // 样式变更走的是观察回调（下一个主队列周期），等它跑完。
        await InlineEditScaffold.drainMainQueue()

        let updated = try #require(canvas.debugAnnotation(id))
        #expect(updated.textHasStroke, "选中的文字要当场带上描边，而不是等下一次输入")
        #expect(updated.textHasCallout, "标注气泡同理")
    }

    @Test("文字：正在输入时切描边，落定之后这条文字就是带描边的")
    func textStrokeAppliesToLiveFieldThenCommit() async throws {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        #expect(canvas.debugSelectTool(.text))

        // 和用户一样：点一下开始输入、打字。
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 400, y: 400)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 400, y: 400)))
        #expect(canvas.debugIsEditingText, "点了该出现输入框")
        #expect(canvas.debugTypeText("星"))

        // 输入框还开着的时候点「描边」。
        canvas.debugSetTextStyle(hasStroke: true, hasCallout: false)
        await InlineEditScaffold.drainMainQueue()
        #expect(canvas.debugIsEditingText, "切样式不该把输入框弄没")

        // 落定 → 这条文字带描边。
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: NSPoint(x: 850, y: 200)))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: NSPoint(x: 850, y: 200)))
        let annotation = try #require(canvas.debugLastTextAnnotation)
        #expect(annotation.textHasStroke, "刚切了描边，落定后就该是描边的字")
        if case .text(_, let string, _) = annotation.kind {
            #expect(string == "星")
        } else {
            Issue.record("最后一条不是文字")
        }
    }

    @Test("文字：点「描边」不会顺手把这条文字的「标注」也改掉")
    func strokeToggleLeavesCalloutAlone() throws {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        // 造一条「带标注」的文字。
        canvas.debugSetTextStyle(hasStroke: false, hasCallout: true)
        let id = try #require(canvas.debugInsertText("星", atViewPoint: CGPoint(x: 300, y: 400)))
        #expect(canvas.debugAnnotation(id)?.textHasCallout == true)

        // 工具栏上的「标注」和这条文字不一致（比如重启后默认是关的），而用户只点了「描边」。
        canvas.debugSetTextStyleWithoutApplying(hasStroke: false, hasCallout: false)
        canvas.debugSetTextStroke(true)

        let annotation = try #require(canvas.debugAnnotation(id))
        #expect(annotation.textHasStroke, "点的就是描边，要生效")
        #expect(annotation.textHasCallout, "没点标注，不能把它抹掉")
    }

    @Test("文字：换工具等无关变化不会把选中文字的描边 / 标注改掉")
    func unrelatedToolbarChangesDoNotClobberTextStyle() async throws {
        let canvas = InlineEditScaffold.makeRestoredCanvas(canvas: CGSize(width: 1000, height: 800))
        // 造一条「带描边 + 标注」的文字。
        canvas.debugSetTextStyle(hasStroke: true, hasCallout: true)
        let id = try #require(canvas.debugInsertText("星", atViewPoint: CGPoint(x: 300, y: 400)))
        #expect(canvas.debugSelectedID == id)

        // 工具栏上的取值和这条文字不一致（用户可能刚在别处调过），但不该因此被抹掉。
        canvas.debugSetTextStyleWithoutApplying(hasStroke: false, hasCallout: false)
        #expect(canvas.debugSelectTool(.rectangle))
        canvas.debugSelectTool(.text)   // 再换回来
        await InlineEditScaffold.drainMainQueue()

        let annotation = try #require(canvas.debugAnnotation(id))
        #expect(annotation.textHasStroke, "换工具不该把描边抹掉")
        #expect(annotation.textHasCallout, "换工具不该把标注抹掉")
    }
}
