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

    var body: some View {
        HStack(spacing: 3) {
            ForEach(RectCornerStyle.allCases) { style in
                let isSelected = selectedStyle == style
                Button {
                    selectedStyle = style
                } label: {
                    RectCornerStyleIcon(
                        style: style,
                        color: isSelected ? Theme.Colors.selectionGreen : Theme.Colors.textSecondary
                    )
                    .frame(width: 28, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? Theme.Colors.controlSurface : Color.black.opacity(0.001))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .focusEffectDisabled()
                .help(style.title)
            }
        }
    }
}
