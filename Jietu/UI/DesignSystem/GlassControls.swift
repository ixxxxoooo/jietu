import SwiftUI

/// 浮动玻璃按钮的角色，决定文字色。
///
/// @author ixxxxoooo
enum GlassButtonRole {
    case standard
    case prominent
    case cancel
    case destructive

    var tint: Color {
        switch self {
        case .standard, .prominent: return Theme.Colors.textPrimary
        case .cancel: return Theme.Colors.textSecondary
        case .destructive: return Theme.Colors.destructive
        }
    }
}

/// 浮动胶囊玻璃按钮：文字（可带图标）+ 悬停墨层 + 玻璃底。
///
/// 规则 5：玻璃只给浮在表面上的控件。
///
/// @author ixxxxoooo
struct GlassButton: View {
    let title: String
    var systemImage: String?
    var role: GlassButtonRole = .standard
    /// 是否用品牌蓝描出主按钮感（权限引导的主操作）。
    var isBranded = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(Theme.Typography.chip)
                }
                Text(title)
                    .font(Theme.Typography.bar)
            }
            .foregroundStyle(isBranded ? Theme.Colors.brand : role.tint)
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(height: Theme.Size.barButtonHeight + Theme.Spacing.md)
            .contentShape(Capsule())
            .background(Capsule().fill(hovered ? Theme.Colors.menuHover : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: Theme.Duration.hover), value: hovered)
        .frosted(in: Capsule())
    }
}

/// 浮动圆形玻璃图标按钮（QAO 四角）。
///
/// @author ixxxxoooo
struct GlassCircleButton: View {
    let title: String
    let systemImage: String
    var diameter: CGFloat = 30
    var tint: Color = Theme.Colors.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: diameter, height: diameter)
        }
        .buttonStyle(.plain)
        .frosted(in: Circle())
        .help(title)
    }
}
