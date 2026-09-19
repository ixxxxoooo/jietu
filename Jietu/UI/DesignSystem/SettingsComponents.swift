import SwiftUI

// 设置页里跨面板复用的少数几件东西；其余一律交给系统 `Form` 的 stock 控件。
//
// 规则：**一条设置行就是一个 stock 控件**（`Toggle` / `Picker` / `LabeledContent`），
// label 用两段式（第一段标题、其余成次级副标题）。只有「尾部是自定义控件」
// （录制器、滑块、按钮组）的行才用 `SettingsRow`。

/// 设置行：标题 / 副标题 + 尾部自定义控件。
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

/// dev 渠道标记：说明当前是 Debug 构建，系统设置里要授权的就是这一条。
///
/// @author ixxxxoooo
struct DevChannelBadge: View {
    var body: some View {
        Text("dev")
            .font(Theme.Typography.compactKeyCap)
            .foregroundStyle(Theme.Colors.accent)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: Theme.Size.recorderKeyCap)
            .background(Capsule().fill(Theme.Colors.accent.opacity(0.15)))
            .help(L10n.buildChannelHelp(AppIdentity.bundleIdentifier))
    }
}

extension View {
    /// 同时压暗并禁用；只用 `.disabled` 的话标题还是全亮，看不出被禁。
    func settingsEnabled(_ isEnabled: Bool) -> some View {
        disabled(!isEnabled).opacity(isEnabled ? 1 : 0.45)
    }
}
