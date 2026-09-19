import AppKit
import SwiftUI

/// 关于：hero（图标 / 名称 / 版本 / 一句话）+ 信息行 + 底部版权。
///
/// 排版照参考项目的 About：hero 在 Form 的第一张卡片里居中，
/// 版本号用 `cardFill` 药丸，底部版权放在 Form **外面**、钉在窗口下沿。
///
/// @author ixxxxoooo
struct AboutSettingsPane: View {
    private static let iconSize: CGFloat = 88

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return L10n.aboutVersion(short, build)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    hero
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.lg)
                }

                Section {
                    LabeledContent(L10n.aboutBuildChannel) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(AppIdentity.isDevChannel ? "Debug" : "Release")
                            if AppIdentity.isDevChannel {
                                DevChannelBadge()
                            }
                        }
                    }
                    LabeledContent("Bundle ID") {
                        Text(AppIdentity.bundleIdentifier)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(L10n.permScreenRecording) {
                        Label(
                            ScreenCapturePermission.isGranted ? L10n.permGranted : L10n.permNotGranted,
                            systemImage: ScreenCapturePermission.isGranted
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(
                            ScreenCapturePermission.isGranted ? Color.green : Color.orange)
                    }
                } header: {
                    SettingsSectionHeader(title: L10n.aboutSectionInfo)
                }

                Section {
                    ForEach(AboutLink.all) { link in
                        AboutLinkRow(link: link)
                    }
                } header: {
                    SettingsSectionHeader(title: L10n.aboutSectionLinks)
                }
            }
            .formStyle(.grouped)

            // 放在 Form 外面，版权才钉在窗口下沿。
            footer
                .padding(.bottom, Theme.Spacing.xxl)
        }
    }

    private var hero: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

            VStack(spacing: Theme.Spacing.sm) {
                Text(AppIdentity.displayName)
                    .font(.title.weight(.bold))
                Text(Self.version)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xs / 2)
                    .background(Capsule().fill(Theme.Colors.cardFill))
                    .overlay(Capsule().strokeBorder(Theme.Colors.cardStroke, lineWidth: 1))
            }

            Text(L10n.aboutTagline)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        Text(L10n.aboutCopyright)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

/// 关于页「链接」卡片里的一条外部目标。
///
/// @author ixxxxoooo
private struct AboutLink: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let url: URL

    /// 仓库地址取自 git remote，避免写死漂移。
    private static let repository = "https://github.com/ixxxxoooo/jietu"

    static let all: [AboutLink] = [
        AboutLink(
            id: "github", symbol: "chevron.left.forwardslash.chevron.right",
            title: "GitHub", detail: "github.com/ixxxxoooo/jietu",
            url: URL(string: repository)!),
        AboutLink(
            id: "issues", symbol: "exclamationmark.bubble",
            title: L10n.aboutIssues, detail: "github.com/ixxxxoooo/jietu/issues",
            url: URL(string: repository + "/issues")!),
    ]
}

/// 一条链接：字形 + 标题，右侧是地址与 ↗，点击用浏览器打开。
///
/// @author ixxxxoooo
private struct AboutLinkRow: View {
    let link: AboutLink

    @State private var hovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(link.url)
        } label: {
            LabeledContent {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(link.detail)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hovered ? .secondary : .tertiary)
                }
            } label: {
                Label {
                    Text(link.title)
                } icon: {
                    Image(systemName: link.symbol)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
