import AppKit
import SwiftUI

/// 取色器的浮卡：**放大镜 + 色号**，跟着光标走。
///
/// 外观全部来自 `PixelLoupeCard` —— 和截图时的放大镜（`LoupeReadoutCard`）是同一个组件，
/// 所以两边永远长得一样：同一块液态玻璃、同样的 136pt 镜面、同样的色值行。
/// 这里只负责取色器自己的读数：色号 + 一句操作提示。
///
/// @author ixxxxoooo
struct ColorPickerCard: View {
    /// 光标周围那一小块实时画面、色号、色块 —— 全在模型里（宿主视图只建一次，靠它刷新）。
    var model: ColorPickerCardModel

    /// 光标那一格永远在镜面正中：探针抓回来的就是「以光标为中心」的 `cells × cells`。
    private static let centerCell = CGPoint(
        x: CGFloat((PixelLoupe.cells - 1) / 2), y: CGFloat((PixelLoupe.cells - 1) / 2)
    )

    var body: some View {
        PixelLoupeCard(image: model.image, cursorCell: Self.centerCell) {
            VStack(alignment: .leading, spacing: 3) {
                PixelLoupeHexRow(hex: model.hex, swatch: model.swatch)

                Text("点击取色 · Esc 取消")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
