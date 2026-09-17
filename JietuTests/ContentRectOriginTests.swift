import AppKit
import Testing

@testable import Jietu

/// 放大镜靠在图层上换 `contentsRect` 来取「光标那一格」的像素，
/// 所以必须钉死 `contentsRect` 的坐标系：它到底以图像**左上**还是**左下**为原点。
///
/// 这个约定错了，放大镜就会整体上下镜像（鼠标在空白处、放大镜里却全是内容）。
///
/// @author ixxxxoooo
@Suite("图层 contentsRect 取像")
@MainActor
struct ContentRectOriginTests {
    /// 8×8：左上角像素红、右下角像素蓝，其余白。行序与 CGImage 一致（第 0 行在上）。
    private func makeImage() -> CGImage {
        var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
        func set(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            let offset = (y * 8 + x) * 4
            bytes[offset] = r
            bytes[offset + 1] = g
            bytes[offset + 2] = b
            bytes[offset + 3] = 255
        }
        set(0, 0, 255, 0, 0)  // 左上红
        set(7, 7, 0, 0, 255)  // 右下蓝
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// 把 4×4 的图层画出来，读「左上角」那个像素的颜色。
    private func topLeftColor(contentRectY: CGFloat) -> String {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
        view.wantsLayer = true
        view.layer?.contents = makeImage()
        view.layer?.contentsGravity = .resize
        view.layer?.magnificationFilter = .nearest
        view.layer?.minificationFilter = .nearest
        view.layer?.contentsRect = CGRect(x: 0, y: contentRectY, width: 0.5, height: 0.5)

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "?" }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let color = rep.colorAt(x: 0, y: 0) else { return "?" }
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }

    /// 由两个探针推出 `contentsRect` 的 y 原点在图像的哪一边。
    private func originDescription() -> String {
        let lower = topLeftColor(contentRectY: 0)
        let upper = topLeftColor(contentRectY: 0.5)
        if lower == "?" || upper == "?" { return "取不到像素（图层没渲染出来）" }
        func isRed(_ hex: String) -> Bool { hex.hasPrefix("#F") && hex.hasSuffix("07") || hex == "#FF0000" }
        if isRed(lower) && !isRed(upper) {
            return "左上（y=0 取到图像顶行）"
        }
        if isRed(upper) && !isRed(lower) {
            return "左下（y=0 取到图像底行）"
        }
        return "无法判定（lower=\(lower) upper=\(upper)）"
    }

    @Test("contentsRect 的 y 原点在图像底边（所以放大镜要翻一次）")
    func contentRectOriginIsBottomEdge() {
        let origin = originDescription()
        #expect(origin == "左下（y=0 取到图像底行）", "实测 contentsRect 原点是：\(origin)")
    }

    /// 放大镜真正依赖的不变式：采样窗口的「左上角」像素，必须出现在图层的左上角。
    @Test("放大镜采样窗口：左上角像素落在图层左上角")
    func loupeContentsRectMapsTopLeftPixel() {
        // 8×8：窗口取 (2,2) 起 4×4，窗口左上 = 红、窗口右下 = 蓝（都在窗口内）。
        var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
        func set(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            let offset = (y * 8 + x) * 4
            bytes[offset] = r
            bytes[offset + 1] = g
            bytes[offset + 2] = b
            bytes[offset + 3] = 255
        }
        set(2, 2, 255, 0, 0)  // 窗口左上
        set(5, 5, 0, 0, 255)  // 窗口右下
        set(2, 5, 0, 200, 0)  // 窗口左下
        set(5, 2, 200, 200, 0)  // 窗口右上
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(
            width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resize
        view.layer?.magnificationFilter = .nearest
        view.layer?.minificationFilter = .nearest
        view.layer?.contentsRect = LoupeGeometry.contentsRect(
            sourceOrigin: CGPoint(x: 2, y: 2),
            cells: 4,
            imageSize: CGSize(width: 8, height: 8)
        )

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("拿不到位图")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        func hex(_ x: Int, _ y: Int) -> String {
            guard let color = rep.colorAt(x: x, y: y) else { return "?" }
            return String(
                format: "#%02X%02X%02X",
                Int((color.redComponent * 255).rounded()),
                Int((color.greenComponent * 255).rounded()),
                Int((color.blueComponent * 255).rounded())
            )
        }
        func isRed(_ hex: String) -> Bool {
            hex != "?" && hex.hasPrefix("#F") && !hex.hasPrefix("#00")
        }
        func isBlue(_ hex: String) -> Bool {
            guard hex != "?", hex.count == 7 else { return false }
            let trimmed = String(hex.dropFirst())
            let red = Int(trimmed.prefix(2), radix: 16) ?? 0
            let green = Int(trimmed.dropFirst(2).prefix(2), radix: 16) ?? 0
            let blue = Int(trimmed.dropFirst(4).prefix(2), radix: 16) ?? 0
            return blue > 0x80 && blue > red + 0x40 && blue > green + 0x40
        }
        // rep 的尺寸跟着屏幕缩放走（2x 屏上是 8×8），角点要按实际像素取。
        let lastX = max(0, rep.pixelsWide - 1)
        let lastY = max(0, rep.pixelsHigh - 1)
        #expect(isRed(hex(0, 0)), "窗口左上应是红色，实际 \(hex(0, 0))")
        #expect(isBlue(hex(lastX, lastY)), "窗口右下应是蓝色，实际 \(hex(lastX, lastY))")
    }
}
