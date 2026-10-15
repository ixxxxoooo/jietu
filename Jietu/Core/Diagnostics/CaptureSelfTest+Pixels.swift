import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 自检共用的像素采样 / 取色小工具。
///
/// @author ixxxxoooo
extension CaptureSelfTest {
    /// 直接向 WindowServer 查询自己的窗口是否真的在屏幕上。
    static func dumpOwnWindows(label: String) {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let own = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        print("--- \(label): \(own.count) own window(s) on screen ---")
        for window in own {
            let number = window[kCGWindowNumber as String] as? Int ?? -1
            let layer = window[kCGWindowLayer as String] as? Int ?? -999
            let alpha = window[kCGWindowAlpha as String] as? Double ?? -1
            let sharing = window[kCGWindowSharingState as String] as? Int ?? -1
            let name = window[kCGWindowName as String] as? String ?? ""
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            print(
                "  win=\(number) layer=\(layer) alpha=\(alpha) sharingState=\(sharing)"
                    + " name=\"\(name)\" bounds=\(bounds)"
            )
        }
    }

    /// 受控对比：同一批像素在「基线」与「遮罩后」两张图里的亮度比。
    static func reportDim(
        _ label: String,
        baseline: CGImage,
        overlay: CGImage,
        rect: CGRect
    ) {
        guard !rect.isEmpty else {
            print("    \(label): 采样区为空，跳过")
            return
        }
        let base = meanLuminance(baseline, pixelRect: rect)
        let over = meanLuminance(overlay, pixelRect: rect)
        let ratio = base > 0.0001 ? over / base : 0
        print(
            String(
                format: "    %@ baseline=%.4f overlay=%.4f ratio=%.3f",
                label, base, over, ratio
            )
        )
    }

    /// local（原点左下、point）→ 图像像素矩形（原点左上）。
    static func pixelRect(forLocalRect rect: CGRect, snapshot: DisplaySnapshot) -> CGRect {
        let scale = snapshot.effectiveScale
        return CGRect(
            x: rect.minX * scale,
            y: (snapshot.screenFrameInPoints.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        .integral
        .intersection(CGRect(origin: .zero, size: snapshot.pixelSize))
    }

    /// 指定像素区域的平均亮度。`cropping` 与调用方都用「原点左上」的像素坐标，
    /// 所以这里不需要再做 Y 翻转。
    static func meanLuminance(_ image: CGImage, pixelRect: CGRect? = nil) -> Double {
        let rgb = meanRGB(image, pixelRect: pixelRect)
        return 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    }

    /// 指定屏幕点（AppKit 全局坐标）附近一块的「绿偏移」均值（G − R）。
    ///
    /// 用来判断某个点是不是**绿色**——绿色对勾在灰度图上只比黑图标亮一点，
    /// 光看亮度分不出来，看 G−R 才有分辨率。
    static func greenBias(
        in snapshot: DisplaySnapshot, at center: CGPoint, size: CGFloat
    ) -> Double {
        let rgb = meanRGB(snapshot.image, pixelRect: pixelRect(in: snapshot, at: center, size: size))
        return rgb.green - rgb.red
    }

    /// 「蓝偏移」（B−R）：识别文本按钮点亮后是品牌蓝实心，探测它比探绿勾更稳。
    static func blueBias(
        in snapshot: DisplaySnapshot, at center: CGPoint, size: CGFloat
    ) -> Double {
        let rgb = meanRGB(snapshot.image, pixelRect: pixelRect(in: snapshot, at: center, size: size))
        return rgb.blue - rgb.red
    }

    /// 屏幕点（AppKit 全局坐标）→ 截图像素矩形。
    static func pixelRect(
        in snapshot: DisplaySnapshot, at center: CGPoint, size: CGFloat
    ) -> CGRect {
        let scale = snapshot.effectiveScale
        let local = CGPoint(
            x: center.x - snapshot.screenFrameInPoints.minX,
            y: center.y - snapshot.screenFrameInPoints.minY
        )
        return CGRect(
            x: (local.x - size / 2) * scale,
            y: (snapshot.screenFrameInPoints.height - local.y - size / 2) * scale,
            width: size * scale,
            height: size * scale
        )
    }

    static func meanRGB(
        _ image: CGImage, pixelRect: CGRect? = nil
    ) -> (red: Double, green: Double, blue: Double) {
        let imageBounds = CGRect(
            origin: .zero,
            size: CGSize(width: image.width, height: image.height)
        )
        let target = (pixelRect ?? imageBounds).intersection(imageBounds)
        guard !target.isEmpty, let crop = image.cropping(to: target) else { return (-1, -1, -1) }

        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return (-1, -1, -1) }

        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red = 0.0
        var green = 0.0
        var blue = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            red += Double(pixels[index]) / 255
            green += Double(pixels[index + 1]) / 255
            blue += Double(pixels[index + 2]) / 255
        }

        let count = Double(width * height)
        return (red / count, green / count, blue / count)
    }
}

#endif
