import AppKit
import SwiftUI
import Testing
@testable import Jietu

@Suite("就地标注工具栏 — 缩放与提交")
struct OverlayCanvasZoomTests {
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

    // MARK: - ⌘D 钉图

    @Test("原地编辑里按 ⌘D：把当前这张（含标注）钉上，交给 onPinImage")
    func commandDPinsAnnotatedImage() throws {
        let (canvas, image) = makeCanvas()
        canvas.restoreImageForInlineEditing(image)

        var pinned: (image: CGImage, rect: CGRect)?
        canvas.onPinImage = { image, rect in pinned = (image, rect) }

        canvas.keyDown(with: commandKeyEvent("d"))

        let pinnedImage = try #require(pinned?.image, "⌘D 应当把当前图交出去钉")
        #expect(pinnedImage.width == image.width && pinnedImage.height == image.height)
        #expect(pinned?.rect == canvas.debugSelection, "钉的位置就是当前选区")
    }

    @Test("还没进标注时按 ⌘D：把当前选区钉上，交给 onPinSelection")
    func commandDPinsCurrentSelection() {
        let (canvas, _) = makeCanvas()
        canvas.debugSetSelection(CGRect(x: 120, y: 90, width: 300, height: 200))

        var pinnedRect: CGRect?
        canvas.onPinSelection = { rect in pinnedRect = rect }
        canvas.keyDown(with: commandKeyEvent("d"))

        #expect(pinnedRect == CGRect(x: 120, y: 90, width: 300, height: 200))
    }

    @Test("拖拽中途按 ⌘D 不算数：不钉一块还没框完的区域")
    func commandDIgnoresUnsettledSelection() {
        let (canvas, _) = makeCanvas()
        canvas.debugSetSelection(CGRect(x: 120, y: 90, width: 300, height: 200))
        // 拖拽中（选区还在变）
        canvas.mouseDown(
            with: mouseEvent(.leftMouseDown, at: NSPoint(x: 120, y: 90))
        )
        canvas.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 420, y: 290))
        )

        var pinnedRect: CGRect?
        canvas.onPinSelection = { rect in pinnedRect = rect }
        canvas.keyDown(with: commandKeyEvent("d"))

        #expect(pinnedRect == nil, "框选还没定下来时不该钉")
    }

    // MARK: - 脚手架

    /// 800×600 的冻结帧 + 一块 1000×800 的遮罩画布（和真实遮罩同一套构造）。
    private func makeCanvas() -> (OverlayCanvasView, CGImage) {
        let ctx = CGContext(
            data: nil,
            width: 800,
            height: 600,
            bitsPerComponent: 8,
            bytesPerRow: 800 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
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
        return (canvas, image)
    }

    private func commandKeyEvent(_ character: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 2 // kVK_ANSI_D
        )!
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        )!
    }
}
