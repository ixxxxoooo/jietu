import SwiftUI

// 引导页自己的卡片样式：设置面板用 stock `Form` 分组，这个窗口不是。

/// 一组引导行的圆角 / 细边容器。
///
/// @author ixxxxoooo
struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.Colors.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Colors.cardStroke, lineWidth: Theme.Size.hairline)
            )
    }
}

/// 卡片内的分隔线：左边缩进到与行标题对齐。
///
/// @author ixxxxoooo
struct OnboardingDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Colors.cardStroke)
            .frame(height: Theme.Size.hairline)
            .padding(.leading, Theme.Spacing.xl + Theme.Size.settingsRowIcon + Theme.Spacing.lg)
    }
}

/// 一条引导行；固定的节奏让卡片不管尾部控件是什么都对得齐。
///
/// @author ixxxxoooo
struct OnboardingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tint: Color = .secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: Theme.Size.settingsRowIcon)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs / 2) {
                Text(title)
                    .font(Theme.Typography.rowTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.rowSubtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.xl)
            trailing
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
    }
}

extension OnboardingRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil, tint: Color = .secondary) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint) {
            EmptyView()
        }
    }
}

/// 状态药丸：已授权 / 未授权这类二元状态。
///
/// @author ixxxxoooo
struct OnboardingStatusBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Capsule().fill(tint.opacity(0.14)))
    }
}
