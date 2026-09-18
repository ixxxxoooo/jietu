import AppKit
import SwiftUI

/// capcap 风格的 HUD 复选按钮（用于文字二级菜单的「描边」与「标注」）。
///
/// @author ixxxxoooo
struct HUDCheckboxButton: View {
    let title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            isSelected
                                ? Theme.Colors.adaptive(
                                    dark: .srgbInk(1, alpha: 0.85),
                                    light: .srgbInk(0, alpha: 0.85)
                                )
                                : Theme.Colors.controlSurface
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(
                                    isSelected
                                        ? Color.clear
                                        : Theme.Colors.border,
                                    lineWidth: 1
                                )
                        )
                        .frame(width: 14, height: 14)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(
                                Theme.Colors.adaptive(
                                    dark: .black,
                                    light: .white
                                )
                            )
                    }
                }

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        isSelected
                            ? Theme.Colors.textPrimary
                            : Theme.Colors.textSecondary
                    )
            }
            .padding(.horizontal, 4)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
