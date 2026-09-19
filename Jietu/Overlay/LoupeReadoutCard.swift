import AppKit
import Observation
import SwiftUI

/// 截图遮罩里那条放大镜读数的状态（卡片只读它，外面改它就刷新）。
///
/// @author ixxxxoooo
@Observable
final class LoupeCardModel {
    /// 镜面：光标周围 `PixelLoupe.cells × cells` 像素那一小块。
    var image: CGImage?
    /// 光标那一格在镜面里的位置（左上角为 0）。贴边时窗口被夹回图内，它会偏离正中。
    var cursorCell: CGPoint = .zero
    /// 光标像素坐标（图像像素、原点左上）。
    var coordinate = "—"
    /// 现在按下去会截到的那块区域（像素尺寸）。
    var region = "—"
    var hex: String?
    var swatch: NSColor?
}

/// 截图遮罩的放大镜卡片：镜面 + 坐标 / 区域 / 色值。
///
/// 外观全部来自 `PixelLoupeCard` —— 和取色器那张是同一个组件。
///
/// @author ixxxxoooo
struct LoupeReadoutCard: View {
    var model: LoupeCardModel

    var body: some View {
        PixelLoupeCard(image: model.image, cursorCell: model.cursorCell) {
            VStack(alignment: .leading, spacing: 3) {
                PixelLoupeReadoutRow(label: "坐标", value: model.coordinate)
                PixelLoupeReadoutRow(label: "区域", value: model.region)
                PixelLoupeHexRow(hex: model.hex, swatch: model.swatch)
            }
        }
    }
}
