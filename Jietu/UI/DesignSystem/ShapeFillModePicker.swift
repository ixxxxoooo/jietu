import AppKit
import SwiftUI

/// 形状填充模式图标（线框、纯色填充、半透明填充）。
///
/// @author ixxxxoooo
struct ShapeFillModeIcon: View {
    let mode: ShapeFillMode
    let color: Color
    var isCircle: Bool = false

    var body: some View {
        ZStack {
            if isCircle {
                switch mode {
                case .none:
                    Circle()
                        .strokeBorder(color, lineWidth: 1.5)
                        .frame(width: 13, height: 13)

                case .opaque:
                    Circle()
                        .fill(color)
                        .frame(width: 13, height: 13)

                case .translucent:
                    Circle()
                        .fill(color.opacity(0.35))
                        .overlay(
                            Circle()
                                .strokeBorder(color, lineWidth: 1.5)
                        )
                        .frame(width: 13, height: 13)
                }
            } else {
                switch mode {
                case .none:
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(color, lineWidth: 1.5)
                        .frame(width: 14, height: 11)

                case .opaque:
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color)
                        .frame(width: 14, height: 11)

                case .translucent:
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .strokeBorder(color, lineWidth: 1.5)
                        )
                        .frame(width: 14, height: 11)
                }
            }
        }
        .frame(width: 18, height: 16)
    }
}

/// 形状填充模式选择器（线框、填充、半透明）。
///
/// @author ixxxxoooo
struct ShapeFillModePicker: View {
    @Binding var selectedMode: ShapeFillMode
    var isCircle: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ShapeFillMode.allCases) { mode in
                let isSelected = selectedMode == mode
                Button {
                    selectedMode = mode
                } label: {
                    ShapeFillModeIcon(
                        mode: mode,
                        color: isSelected ? Theme.Colors.selectionGreen : Theme.Colors.textSecondary,
                        isCircle: isCircle
                    )
                    .frame(width: 28, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? Theme.Colors.controlSurface : Color.black.opacity(0.001))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
    }
}
