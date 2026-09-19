import AppKit
import ScreenCaptureKit

/// 屏幕取色器用的**像素探针**：抓光标周围那一小块实时画面。
///
/// 为什么是 ScreenCaptureKit：`CGDisplayCreateImage` 在 macOS 15 已被废除，而 SCK 抓
/// 13×13 像素这种小区域只要 ~16ms（实测），足够跟着光标跑。取回的字节与系统取色器
/// 报的色一致（受控纯色对比过：都报 `#E03030`）。
///
/// 放大镜的取样窗口与截图时的放大镜同一套尺寸（`PixelLoupe`）：
/// 光标那一个像素永远在正中，所以探针抓回来的图不用再算裁剪 —— 它**就是**镜面。
///
/// @author ixxxxoooo
@MainActor
final class ScreenPixelProbe {
    /// 一次取色的结果。
    struct PickedColor {
        /// `#RRGGBB`（大写）。
        let hex: String
        /// 原始分量，用于回执浮窗上那枚色块。
        let sample: PixelSampler.Sample

        /// 画色块用的颜色。
        var nsColor: NSColor { sample.nsColor }
    }

    /// 采样窗口的边长（像素）：和放大镜的格数一样，奇数格 → 光标那格在正中。
    static let cells = PixelLoupe.cells

    private let filter: SCContentFilter
    private let scale: CGFloat
    private let configuration: SCStreamConfiguration

    /// 为某块屏建探针（`displayID` 与 `NSScreen.jietu_displayID` 同一套口径）。
    init(displayID: CGDirectDisplayID, scale: CGFloat) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
        else { throw CaptureError.noDisplays }

        // 把自己排除掉：取色器的浮卡与放大镜不能被拍进镜面里。
        let excluded = content.applications.filter { $0.processID == getpid() }
        filter = SCContentFilter(
            display: display, excludingApplications: excluded, exceptingWindows: []
        )
        self.scale = scale

        let config = SCStreamConfiguration()
        config.width = Self.cells
        config.height = Self.cells
        config.showsCursor = false
        config.captureResolution = .best
        // 报出来的色要跟系统取色器一致：按 sRGB 取值，而不是显示器的原生色彩空间。
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB), let name = srgb.name {
            config.colorSpaceName = name
        }
        configuration = config
    }

    /// 抓「以光标所在像素为中心」的 `cells × cells` 画面。
    ///
    /// - Parameter cursorPointInPixels: 光标在该屏内的像素坐标（原点左上，已乘缩放）。
    func capture(around cursorPointInPixels: CGPoint) async throws -> CGImage? {
        let origin = Self.windowOrigin(cursorPointInPixels: cursorPointInPixels)
        let configuration = self.configuration
        configuration.sourceRect = CGRect(
            x: origin.x / scale,
            y: origin.y / scale,
            width: CGFloat(Self.cells) / scale,
            height: CGFloat(Self.cells) / scale
        )
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )
    }

    /// 镜面窗口的左上角（像素）：以光标像素为中心，向左上各让出半格。
    ///
    /// 纯函数，单测直接钉它：偏一格，整面镜子里的像素就全错位了。
    static func windowOrigin(cursorPointInPixels: CGPoint) -> CGPoint {
        let half = CGFloat((cells - 1) / 2)
        return CGPoint(
            x: (cursorPointInPixels.x - half).rounded(.down),
            y: (cursorPointInPixels.y - half).rounded(.down)
        )
    }

    /// 从镜面里取正中那一格 —— 也就是光标指着的像素。
    static func centerSample(of image: CGImage) -> PixelSampler.Sample? {
        PixelSampler.sample(
            image, atPixel: CGPoint(x: image.width / 2, y: image.height / 2)
        )
    }
}
