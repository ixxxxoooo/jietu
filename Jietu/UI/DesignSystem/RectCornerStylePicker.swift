import AppKit
import SwiftUI

/// 矩形角样式图标（方角 / 圆角）。
///
/// @author ixxxxoooo
struct RectCornerStyleIcon: View {
    let style: RectCornerStyle
    let color: Color

    var body: some View {
        ZStack {
            switch style {
            case .square:
                Rectangle()
                    .strokeBorder(color, lineWidth: 1.5)
                    .frame(width: 14, height: 11)

            case .rounded:
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(color, lineWidth: 1.5)
                    .frame(width: 14, height: 11)
            }
        }
        .frame(width: 18, height: 16)
    }
}

/// 矩形角样式选择器（方角 / 圆角）。
///
/// @author ixxxxoooo
struct RectCornerStylePicker: View {
    @Binding var selectedStyle: RectCornerStyle
    /// 竖排（二级菜单竖着排时）。
    var isVertical: Bool = false

    var body: some View {
        StyleIconPicker(
            selected: $selectedStyle,
            isVertical: isVertical,
            title: \.title,
            icon: { style, isSelected in
                RectCornerStyleIcon(
                    style: style,
                    color: isSelected ? Theme.Colors.selectionGreen : Theme.Colors.toolbarIcon
                )
            }
        )
    }
}
