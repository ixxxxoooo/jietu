import SwiftUI

/// 单个按键芯片：`.outline` 用于行上的热键提示，`.filled` 用于底栏 / 录制态。
///
/// 三档尺寸是明确的选择，不是随手写个 frame。
///
/// @author ixxxxoooo
struct KeyCapChip: View {
    enum Style {
        case outline
        case filled
    }

    /// 允许的芯片尺寸档。
    enum Scale {
        case compact
        case standard
        case hero

        var side: CGFloat {
            switch self {
            case .compact: Theme.Size.compactKeyCap
            case .standard: Theme.Size.keyCap
            case .hero: Theme.Size.heroKeyCap
            }
        }

        var font: Font {
            switch self {
            case .compact: Theme.Typography.compactKeyCap
            case .standard: Theme.Typography.keyCap
            case .hero: Theme.Typography.heroKeyCap
            }
        }
    }

    let text: String
    var style: Style = .filled
    var scale: Scale = .standard
    /// 文字颜色，默认次级墨色。
    var tint: Color = Theme.Colors.textSecondary

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.keyCap, style: .continuous)
        Text(text)
            .font(scale.font)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.xs)
            .frame(minWidth: scale.side, minHeight: scale.side)
            .background {
                switch style {
                case .filled:
                    shape.fill(Theme.Colors.controlSurface)
                case .outline:
                    shape.strokeBorder(Theme.Colors.border, lineWidth: Theme.Size.hairline)
                }
            }
    }
}
