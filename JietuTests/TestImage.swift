import CoreGraphics
import Foundation

/// 测试用的小尺寸位图工厂。
///
/// @author ixxxxoooo
enum TestImage {
    /// 逐行生成图像，`rows[0]` 是**顶行**（CGImage 原点在左上）。
    /// 每行内的颜色相同，便于用行序验证 Y 轴翻转换算。
    static func horizontalBands(
        width: Int,
        height: Int,
        rows: [(UInt8, UInt8, UInt8)]
    ) -> CGImage {
        make(width: width, height: height) { _, y in
            rows[min(y, rows.count - 1)]
        }
    }

    /// 用逐像素回调生成图像（坐标原点左上）。
    static func make(
        width: Int,
        height: Int,
        color: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) -> CGImage {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = color(x, y)
                bytes.append(rgb.0)
                bytes.append(rgb.1)
                bytes.append(rgb.2)
                bytes.append(255)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// 8×8 纯黑图。
    static func solidBlack(side: Int = 8) -> CGImage {
        horizontalBands(width: side, height: side, rows: [(0, 0, 0)])
    }
}
