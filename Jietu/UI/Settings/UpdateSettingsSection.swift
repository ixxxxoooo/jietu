import AppKit
import SwiftUI

/// 关于页里的「软件更新」分组：版本 / 检查 / 新版本详情 / 下载进度 / 失败重试。
///
/// 只读 `UpdateManager.state`，所有动作都回调给 manager，自己不持有任何流程状态。
///
/// @author ixxxxoooo
struct UpdateSettingsSection: View {
    @Bindable var updates: UpdateManager

    /// 手动下载入口（自动更新走不通时的兜底）。
    private static let releasesURL = URL(string: "https://github.com/ixxxxoooo/jietu/releases/latest")!

    var body: some View {
        Section {
            LabeledContent(L10n.updateCurrentVersion) {
                Text(updates.current.description)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            statusRow

            Toggle(L10n.updateAutoCheck, isOn: Bindable(updates.preferences).autoCheck)
        } header: {
            SettingsSectionHeader(title: L10n.updateSection)
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(L10n.updateFooter)
                if AppIdentity.isDevChannel {
                    Text(L10n.updateDevNote)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 状态行

    @ViewBuilder
    private var statusRow: some View {
        switch updates.state {
        case .idle:
            LabeledContent {
                checkButton
            } label: {
                if let last = updates.preferences.lastCheck {
                    Text(L10n.updateLastChecked(last.formatted(date: .abbreviated, time: .shortened)))
                        .foregroundStyle(.secondary)
                }
            }
        case .checking:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(L10n.updateChecking).foregroundStyle(.secondary)
            }
        case .upToDate:
            LabeledContent {
                checkButton
            } label: {
                Label(L10n.updateUpToDate, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .available(let release):
            availableView(release)
        case .downloading(let release, let progress):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(L10n.updateAvailableTitle(release.version.description)).font(.headline)
                ProgressView(value: progress)
                HStack {
                    Text(L10n.updateDownloading(Int(progress * 100)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.updateCancel) { updates.cancelInstall() }
                }
            }
        case .verifying(let release):
            busyView(release, L10n.updateVerifying)
        case .installing(let release):
            busyView(release, L10n.updateInstalling)
        case .failed(let message):
            failedView(message)
        }
    }

    private var checkButton: some View {
        Button(L10n.updateCheckNow) {
            Task { await updates.check(userInitiated: true) }
        }
    }

    private func availableView(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label(L10n.updateAvailableTitle(release.version.description), systemImage: "arrow.down.circle.fill")
                .font(.headline)
                .foregroundStyle(Color.accentColor)

            if !release.notes.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(L10n.updateReleaseNotes)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(Self.renderNotes(release.notes))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                Button(L10n.updateInstall) { updates.installAvailableUpdate() }
                    .buttonStyle(.borderedProminent)
                Button(L10n.updateSkip) { updates.skipAvailableVersion() }
                Spacer()
                Button(L10n.updateViewRelease) { NSWorkspace.shared.open(release.pageURL) }
                    .buttonStyle(.link)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func busyView(_ release: ReleaseInfo, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(L10n.updateAvailableTitle(release.version.description)).font(.headline)
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Spacing.sm) {
                checkButton.buttonStyle(.borderedProminent)
                if let app = updates.manualInstallURL {
                    Button(L10n.updateShowInFinder) { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                }
                Button(L10n.updateManualDownload) { NSWorkspace.shared.open(Self.releasesURL) }
                Spacer()
                Button(L10n.updateDismiss) { updates.dismissFailure() }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    /// Release 正文是 Markdown：能渲染就渲染（保留换行），失败回退原文。
    private static func renderNotes(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: GitHubReleaseParser.displayMarkdown(markdown), options: options))
            ?? AttributedString(markdown)
    }
}
