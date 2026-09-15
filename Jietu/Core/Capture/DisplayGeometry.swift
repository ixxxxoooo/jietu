import AppKit
import CoreGraphics

/// 坐标系换算的唯一入口。
///
/// 三套坐标系必须分清，所有换算都收敛在这里，禁止在别处手算：
/// - **local**：某个遮罩画布内的 view 坐标，原点在该显示器左下角
/// - **appKit**：AppKit 全局坐标，原点在主显示器左下角
/// - **cg**：CoreGraphics 全局坐标，原点在主显示器**左上**角
///
/// 窗口列表（`CGWindowListCopyWindowInfo`）与 `CGDisplayBounds` 用的是 cg。
enum DisplayGeometry {
    /// 原点所在的显示器（`NSScreen.main` 是「有 key window 的屏」，不是这个）。
    static var referenceScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    /// 主显示器高度，cg↔appKit 的 Y 轴翻转基准。
    static var referenceHeight: CGFloat {
        referenceScreen?.frame.height ?? 0
    }

    static func appKitPoint(fromLocal point: CGPoint, screen: NSScreen) -> CGPoint {
        CGPoint(x: screen.frame.minX + point.x, y: screen.frame.minY + point.y)
    }

    static func localPoint(fromAppKit point: CGPoint, screen: NSScreen) -> CGPoint {
        CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)
    }

    /// local 点 → cg 点。
    static func cgPoint(fromLocal point: CGPoint, screen: NSScreen) -> CGPoint {
        let appKit = appKitPoint(fromLocal: point, screen: screen)
        return CGPoint(x: appKit.x, y: referenceHeight - appKit.y)
    }

    /// cg 点 → local 点。
    static func localPoint(fromCG point: CGPoint, screen: NSScreen) -> CGPoint {
        let appKit = CGPoint(x: point.x, y: referenceHeight - point.y)
        return localPoint(fromAppKit: appKit, screen: screen)
    }

    /// cg 矩形 → local 矩形。注意 cg 的 origin 是左上，换算后要改取底边。
    static func localRect(fromCGRect rect: CGRect, screen: NSScreen) -> CGRect {
        let bottomInAppKit = referenceHeight - rect.maxY
        return CGRect(
            x: rect.minX - screen.frame.minX,
            y: bottomInAppKit - screen.frame.minY,
            width: rect.width,
            height: rect.height
        )
    }
}
