import AppKit
import SwiftUI

/// 对齐 CleanShot 的视觉规格。数值集中在这里，方便后续逐像素微调。
enum Theme {
    // MARK: - Color

    /// CleanShot 品牌蓝。
    static let brand = Color(red: 0x0D / 255, green: 0x44 / 255, blue: 0xE8 / 255)

    /// 截图选框的绿色（参考 CleanShot：绿色虚线选框 + 绿色控制点）。
    static let selectionGreen = Color(red: 0.14, green: 0.87, blue: 0.45)

    static let hudForeground = Color.white.opacity(0.6)
    static let hudForegroundActive = Color.white
    static let hudSelectionFill = Color.white.opacity(0.1)

    /// 选区外压暗程度。
    static let overlayDimAlpha: CGFloat = 0.45

    // MARK: - Metrics

    static let hudCornerRadius: CGFloat = 12
    static let buttonCornerRadius: CGFloat = 8
    static let toolbarPadding: CGFloat = 8
    static let toolbarItemSpacing: CGFloat = 4
    static let toolbarIconSize: CGFloat = 17

    static let selectionBorderWidth: CGFloat = 1
    static let selectionHandleSize: CGFloat = 6
    /// 判定「抓到了 handle」的半径，比 handle 本身大，好抓。
    static let selectionHandleHitTolerance: CGFloat = 9
    /// 超过这个位移才算框选，否则算单击。
    static let dragActivationDistance: CGFloat = 3
    /// 小于这个尺寸的框选视为误触。与 `SelectionGeometry.minimumSide` 同源。
    static let minimumSelectionSize: CGFloat = SelectionGeometry.minimumSide

    static let quickAccessWidth: CGFloat = 240
    static let quickAccessCornerRadius: CGFloat = 12
    static let quickAccessInset: CGFloat = 20
    /// 给 SwiftUI 阴影留的空间。窗口自身阴影是直角矩形，必须关掉换成这个。
    static let quickAccessShadowPadding: CGFloat = 14

    // MARK: - Motion

    static let toolbarFadeIn: TimeInterval = 0.15
    static let quickAccessSlideIn: TimeInterval = 0.25
}
