import AppKit
import SwiftUI

/// capcap 风格的 8 色调色板。
///
/// 选中时外侧带 22pt 绿色圆环与 2pt 透明空隙。
///
/// @author ixxxxoooo
struct ColorSwatchesView: View {
    @Binding var selectedColor: RGBAColor
    var palette: [RGBAColor] = RGBAColor.palette
    /// 竖排（二级菜单竖着排时）：色板变成一列。
    var isVertical: Bool = false

    var body: some View {
        if isVertical {
            VStack(spacing: 4) {
                ForEach(palette, id: \.self) { swatch in
                    swatchButton(swatch)
                }
            }
        } else {
            HStack(spacing: 6) {
                ForEach(palette, id: \.self) { swatch in
                    swatchButton(swatch)
                }
            }
        }
    }

    @ViewBuilder
    private func swatchButton(_ swatch: RGBAColor) -> some View {
        let isSelected = selectedColor == swatch
        Button {
            selectedColor = swatch
        } label: {
            ZStack {
                // 选中外圈绿色光环
                if isSelected {
                    Circle()
                        .strokeBorder(Theme.Colors.selectionGreen, lineWidth: 2)
                        .frame(width: 22, height: 22)
                }

                // 色块圆点
                Circle()
                    .fill(swatch.swiftUIColor)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                swatch == .white
                                    ? Theme.Colors.adaptive(
                                        dark: .srgbInk(1, alpha: 0.25),
                                        light: .srgbInk(0, alpha: 0.18)
                                    )
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

extension RGBAColor {
    /// UI 层的 SwiftUI 颜色桥接。
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
