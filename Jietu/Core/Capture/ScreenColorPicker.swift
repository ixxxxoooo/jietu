import AppKit

/// 屏幕取色：调系统那套放大镜（`NSColorSampler`）选一个像素，把色号写进剪贴板。
///
/// 为什么用系统的采样器（capcap 也是这条）而不是自己搭遮罩：光标变放大镜、Esc 取消、
/// 跨显示器取色、被取色的窗口不需要被我们的遮罩挡住——这些系统都给了，自己搭一遍只会更差。
///
/// 色号写法与放大镜 / 标注界面的「色值」完全一致：`#RRGGBB` 大写，格式由
/// `PixelSampler.Sample.hexString` 一处说了算。
///
/// @author ixxxxoooo
@MainActor
final class ScreenColorPicker {
    static let shared = ScreenColorPicker()

    /// 一次取色的结果。
    struct PickedColor {
        /// `#RRGGBB`（大写）。
        let hex: String
        /// 原色，用于提示浮窗上那枚色块。
        let color: NSColor
    }

    /// 放大镜正开着吗。开着一份就不再叠第二个。
    private(set) var isPicking = false

    private init() {}

    /// 弹系统放大镜；选中后把色号复制到剪贴板，再把结果交给外面。
    ///
    /// - Parameter completion: 用户按 Esc 取消时回调 `nil`（那时不写剪贴板）。
    func pick(completion: @escaping (PickedColor?) -> Void) {
        guard !isPicking else { return }
        isPicking = true
        Task {
            // `sample()` 是系统的 async 版；回调固定在主线程，取消时返回 nil。
            let color = await NSColorSampler().sample()
            isPicking = false
            guard let color, let hex = color.jietu_hexString else {
                completion(nil)
                return
            }
            CaptureOutput.copyToPasteboard(hex)
            completion(PickedColor(hex: hex, color: color))
        }
    }
}

extension NSColor {
    /// 取色器 / 放大镜共用的色号写法：`#RRGGBB`（大写）。
    ///
    /// 先换算到 sRGB 再取分量：系统放大镜给的颜色可能在别的色彩空间（P3、灰度…），
    /// 直接读 `redComponent` 会抛异常或给出对不上的值。
    var jietu_hexString: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        // 格式只此一处定义（见 `PixelSampler.Sample.hexString`）。
        return PixelSampler.Sample(
            red: byte(srgb.redComponent),
            green: byte(srgb.greenComponent),
            blue: byte(srgb.blueComponent),
            alpha: byte(srgb.alphaComponent)
        ).hexString
    }
}
