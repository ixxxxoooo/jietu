import AppKit
import SwiftUI
import Testing
@testable import Jietu

/// 就地编辑测试的共享脚手架。
///
/// @author ygw
enum InlineEditScaffold {
    /// 造一块普通原地编辑画布：快照底图与画布同比例（`effectiveScale` == `scale`）。
    static func makeCanvas(canvas size: CGSize, scale: CGFloat = 2) -> OverlayCanvasView {
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
    static func makeRestoredCanvas(
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

    static func makeImage(width: Int, height: Int) -> CGImage {
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

    /// 造一块**区域截图**的原地编辑画布：拖一块选区进标注（第一次截图那条路）。
    static func makeInlineRegionCanvas(region: CGRect) -> OverlayCanvasView {
        let canvas = makeCanvas(canvas: CGSize(width: 1000, height: 800))
        canvas.inlineMode = true
        canvas.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: region.minX, y: region.minY)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: region.maxX, y: region.maxY)))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: region.maxX, y: region.maxY)))
        return canvas
    }

    /// 等主队列上排着的观察回调跑完（样式变更走的是 `DispatchQueue.main.async`）。
    static func drainMainQueue() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 造一个按键事件（`keyCode` 用 AppKit 的原始码，53 = Esc、36 = Return）。
    static func key(_ keyCode: UInt16) -> NSEvent {
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

    static func mouse(
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
    static func cropDrag(_ canvas: OverlayCanvasView, to rect: CGRect) {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: rect.maxX, y: rect.maxY)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: rect.minX, y: rect.minY)))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: rect.minX, y: rect.minY)))
    }

    /// 双击确认裁剪。
    static func confirmCrop(_ canvas: OverlayCanvasView, atPoint point: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: point, clickCount: 2))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: point, clickCount: 2))
    }

    /// 屏幕矩形 → 图像像素矩形。`frame` 是该图在屏幕上的位置，`imageOrigin` 是这张图左上角在
    /// **原始底图**里的像素坐标（第一次裁剪传 .zero，之后传上一层裁出来的原点）。
    static func pixelRect(
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
    static func makeGradientImage(width: Int, height: Int) -> CGImage {
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
    static func samePixels(_ a: CGImage?, _ b: CGImage?) -> Bool {
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
}
