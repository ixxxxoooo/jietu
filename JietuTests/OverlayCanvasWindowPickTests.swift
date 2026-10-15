import AppKit
import Testing
@testable import Jietu

/// 窗口截图（专选窗口模式）的点选：点哪个窗口就是哪个窗口。
@Suite("遮罩画布 — 窗口截图点选")
@MainActor
struct OverlayCanvasWindowPickTests {
    private static func window(_ id: CGWindowID, _ frame: CGRect) -> WindowInfo {
        WindowInfo(
            windowID: id, ownerPID: 1, ownerName: "App\(id)", title: "", layer: 0,
            frameInCGPoints: frame
        )
    }

    /// 两个窗口：`front`（id 2，小）压在 `back`（id 1，大）上面，列表按前后顺序排好。
    private static func makeCanvas(inlineMode: Bool) -> (OverlayCanvasView, WindowInfo, WindowInfo) {
        let back = window(1, CGRect(x: 100, y: 100, width: 800, height: 600))
        let front = window(2, CGRect(x: 600, y: 400, width: 200, height: 200))
        // 画布与所在屏幕同大：窗口的 CG 坐标换成 view 坐标要用屏幕高度，尺寸对不上窗口会落到画布外。
        let size = NSScreen.screens.first?.frame.size ?? CGSize(width: 1000, height: 800)
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(origin: .zero, size: size),
            nominalScaleFactor: 2,
            image: TestImage.solidColor(
                width: Int(size.width * 2), height: Int(size.height * 2), r: 0, g: 0, b: 0)
        )
        let canvas = OverlayCanvasView(
            snapshot: snapshot,
            session: CaptureSession(snapshots: [snapshot], windows: [front, back]),
            displayIndex: 1,
            displayCount: 1
        )
        canvas.frame = NSRect(origin: .zero, size: size)
        canvas.inlineMode = inlineMode
        canvas.isWindowOnlyMode = true
        return (canvas, front, back)
    }

    /// 窗口某一点（CG 坐标）在遮罩里对应的 local 点。
    private static func local(_ cg: CGPoint, in canvas: OverlayCanvasView) -> NSPoint {
        let rect = DisplayGeometry.localRect(
            fromCGRect: CGRect(origin: cg, size: CGSize(width: 1, height: 1)),
            screen: canvas.screen
        )
        return NSPoint(x: rect.minX, y: rect.minY)
    }

    private static func click(_ canvas: OverlayCanvasView, at point: NSPoint) {
        canvas.mouseDown(with: InlineEditScaffold.mouse(.leftMouseDown, at: point))
        canvas.mouseUp(with: InlineEditScaffold.mouse(.leftMouseUp, at: point))
    }

    @Test("原地编辑模式下单击窗口：选区就是点中的那个窗口，而不是别的")
    func inlineModeSelectsClickedWindow() {
        let (canvas, _, back) = Self.makeCanvas(inlineMode: true)

        // 悬停在前面的小窗口上，再点后面窗口露出来的地方。
        canvas.mouseMoved(
            with: InlineEditScaffold.mouse(.mouseMoved, at: Self.local(CGPoint(x: 700, y: 500), in: canvas))
        )
        Self.click(canvas, at: Self.local(CGPoint(x: 150, y: 150), in: canvas))

        let expected = DisplayGeometry.localRect(
            fromCGRect: back.frameInCGPoints, screen: canvas.screen
        ).intersection(canvas.bounds)
        #expect(canvas.isAnnotationPhase)
        #expect(canvas.debugSelection == expected)
    }

    @Test("窗口被压住的部分换成它自己的干净画面，窗口以外的像素不动")
    func cleanWindowReplacesOccludedPixels() throws {
        let (canvas, _, back) = Self.makeCanvas(inlineMode: true)
        // 冻结画面是全黑的；窗口自己的画面是纯红。
        let clean = TestImage.solidColor(width: 1600, height: 1200, r: 255, g: 0, b: 0)
        let frame = DisplayGeometry.localRect(fromCGRect: back.frameInCGPoints, screen: canvas.screen)

        Self.click(canvas, at: Self.local(CGPoint(x: 150, y: 150), in: canvas))
        canvas.applyCleanWindow(clean, windowFrameInView: frame)

        let scale = canvas.snapshot.effectiveScale
        let image = canvas.snapshot.image
        // 窗口中心（像素坐标原点左上）：红。
        let inside = PixelSampler.sample(
            image,
            atPixel: CGPoint(
                x: frame.midX * scale, y: (canvas.bounds.height - frame.midY) * scale
            )
        )
        #expect(try #require(inside).red == 255)
        // 画面左上角在窗口外：仍是黑。
        let outside = PixelSampler.sample(image, atPixel: CGPoint(x: 2, y: 2))
        #expect(try #require(outside).red == 0)
        // 编辑用的底图（裁出来的选区）也是干净的。
        let crop = try #require(canvas.cropImage)
        #expect(try #require(PixelSampler.sample(crop, atPixel: CGPoint(x: 10, y: 10))).red == 255)
    }

    @Test("以点击的位置为准：悬停停在前面的窗口上、点的却是后面的窗口，截后面那个")
    func clickWinsOverStaleHover() {
        let (canvas, front, back) = Self.makeCanvas(inlineMode: false)
        var picked: WindowInfo?
        canvas.onWindowSelected = { picked = $0 }

        // 先悬停到最前面的小窗口上……
        canvas.mouseMoved(
            with: InlineEditScaffold.mouse(.mouseMoved, at: Self.local(CGPoint(x: 700, y: 500), in: canvas))
        )
        #expect(canvas.hoveredWindow?.windowID == front.windowID)

        // ……然后不移动鼠标事件，直接在后面窗口露出来的地方按下 / 松开。
        Self.click(canvas, at: Self.local(CGPoint(x: 150, y: 150), in: canvas))

        #expect(picked?.windowID == back.windowID)
    }

    @Test("没有悬停过也能点：按下的那一点直接命中窗口")
    func clickWithoutPriorHover() {
        let (canvas, front, _) = Self.makeCanvas(inlineMode: false)
        var picked: WindowInfo?
        canvas.onWindowSelected = { picked = $0 }

        Self.click(canvas, at: Self.local(CGPoint(x: 700, y: 500), in: canvas))

        #expect(picked?.windowID == front.windowID)
    }

    @Test("点在任何窗口之外：什么也不截")
    func clickOutsideAnyWindowDoesNothing() {
        let (canvas, _, _) = Self.makeCanvas(inlineMode: true)
        var picked: WindowInfo?
        canvas.onWindowSelected = { picked = $0 }

        Self.click(canvas, at: Self.local(CGPoint(x: 20, y: 20), in: canvas))

        #expect(picked == nil)
    }
}
