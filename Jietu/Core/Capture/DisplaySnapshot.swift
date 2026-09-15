import AppKit
import CoreGraphics

/// 一次「冻结屏幕」：某块显示器在按下热键那一刻的完整画面。
struct DisplaySnapshot {
    let displayID: CGDirectDisplayID
    /// AppKit 全局坐标（原点左下、单位 point）。
    let screenFrameInPoints: CGRect
    /// `NSScreen.backingScaleFactor`，仅作参考。
    let nominalScaleFactor: CGFloat
    let image: CGImage

    var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    /// 真实比例。缩放显示器 / 非默认密度下会与 `nominalScaleFactor` 不一致，
    /// 所有 point→pixel 换算必须走这个值。
    var effectiveScale: CGFloat {
        screenFrameInPoints.width > 0
            ? CGFloat(image.width) / screenFrameInPoints.width
            : nominalScaleFactor
    }

    /// 把本显示器内的 view 坐标（原点左下、point）换算成图像像素坐标（原点左上）。
    func pixelPoint(fromLocalPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * effectiveScale,
            y: (screenFrameInPoints.height - point.y) * effectiveScale
        )
    }
}

extension NSScreen {
    var jietu_displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}
