import SwiftUI

/// 设置页里跨面板复用的几个小组件；其余交给系统 `Form` 分组。
///
/// 不用 `LabeledContent`：它的可选中文本框会吃掉快捷键录制器需要的点击。
///
/// @author ixxxxoooo
struct SettingsRow<Icon: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleLineLimit = 2
    /// 副标题着色；nil 用系统 `.secondary`，冲突 / 警告时传 `Theme.Colors.warning`。
    var subtitleTint: Color?
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            icon
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.rowSubtitle)
                        .foregroundStyle(subtitleTint ?? Color.secondary)
                        .lineLimit(subtitleLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.middle)
                        .help(subtitle)
                }
            }
            Spacer(minLength: Theme.Spacing.lg)
            trailing
        }
    }
}

extension SettingsRow where Icon == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        subtitleLineLimit: Int = 2,
        subtitleTint: Color? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            subtitleTint: subtitleTint,
            icon: { EmptyView() },
            trailing: trailing
        )
    }
}

/// 设置行首的图标槽，固定宽高让每一列的标题对齐同一条 x。
///
/// @author ixxxxoooo
struct SettingsIcon: View {
    let systemImage: String
    var tint: Color = Theme.Colors.textSecondary

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: Theme.Size.settingsRowIcon, height: Theme.Size.settingsRowIcon)
    }
}

/// 分组标题：比行标题小、次级墨色。
///
/// @author ixxxxoooo
struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.Typography.sectionHeader)
            .foregroundStyle(Theme.Colors.textSecondary)
    }
}

/// 卡片底 + 描边，用于把一组说明内容围起来（权限状态、默认样式摘要）。
///
/// @author ixxxxoooo
struct SettingsCard<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.xl
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Theme.Colors.cardFill))
            .overlay(shape.strokeBorder(Theme.Colors.cardStroke, lineWidth: Theme.Size.hairline))
    }
}

extension View {
    /// 同时压暗并禁用；只用 `.disabled` 的话标题还是全亮，看不出被禁。
    func settingsEnabled(_ isEnabled: Bool) -> some View {
        disabled(!isEnabled).opacity(isEnabled ? 1 : 0.45)
    }
}

/// 带主题色图标的设置行：图标 + 标题 / 副标题 + 尾部任意控件。
///
/// 设置页每个分区用一个 `Theme.Colors.Accent`，侧边栏与内容区因此配色一致。
///
/// @author ixxxxoooo
struct SettingsControlRow<Trailing: View>: View {
    let icon: String
    var tint: Color = Theme.Colors.textSecondary
    let title: String
    var subtitle: String?
    var subtitleLineLimit = 2
    /// 关掉时压暗并禁用（例如 JPEG 质量只在 JPEG 下生效）。
    var isActive = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        SettingsRow(
            title: title,
            subtitle: subtitle,
            subtitleLineLimit: subtitleLineLimit,
            icon: { SettingsIcon(systemImage: icon, tint: tint) },
            trailing: { trailing }
        )
        .settingsEnabled(isActive)
    }
}

/// 带主题色图标的开关行。
///
/// @author ixxxxoooo
struct SettingsToggleRow: View {
    let icon: String
    var tint: Color = Theme.Colors.textSecondary
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(
            title: title,
            subtitle: subtitle,
            icon: { SettingsIcon(systemImage: icon, tint: tint) }
        ) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}
