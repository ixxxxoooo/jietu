import CoreGraphics
import Foundation

/// 从冻结图里取单像素颜色（放大镜下的取色器要用）。
///
/// 做法是「裁 1×1 再画 1×1」，而不是把整张 5K 图解码成 BGRA 大缓冲：
/// 后者要多占 ~60MB/屏，而 `cropping` 是惰性的。代价是每次都走一遍
/// CoreGraphics，所以调用方需要节流（见 `OverlayCanvasView` 的采样节流）。
enum PixelSampler {
    struct Sample {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        /// 不透明度。截图都是不透明的，只有「透明底的标注图层」才会用到它。
        let alpha: UInt8

        var hexString: String {
            String(format: "#%02X%02X%02X", red, green, blue)
        }
    }

    /// `point` 是图像内的像素坐标（原点左上）。
    static func sample(_ image: CGImage, atPixel point: CGPoint) -> Sample? {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: 4)
        guard
            let context = CGContext(
                data: &buffer,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Sample(red: buffer[0], green: buffer[1], blue: buffer[2], alpha: buffer[3])
    }
}
