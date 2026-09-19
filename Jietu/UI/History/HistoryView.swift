import AppKit
import SwiftUI

/// 托盘历史面板：兼容旧调用。
struct HistoryView: View {
    let items: [HistoryItem]
    var onSelect: (HistoryItem) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(Theme.Typography.bar)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(L10n.historyTitle)
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer(minLength: Theme.Spacing.md)
                GlassButton(title: L10n.historyDone, role: .cancel, action: onClose)
            }
            .padding(.leading, Theme.Spacing.xl)
            .padding(.trailing, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)

            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: Theme.Size.hairline)

            RecentHistoryMenuView(
                items: items,
                onSelect: onSelect,
                onRevealInFinder: { item in
                    if let url = item.url {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                },
                onCopy: { item in
                    if let cg = item.resolvedCGImage {
                        CaptureOutput.copyToPasteboard(cg)
                    }
                },
                onPin: nil,
                onClear: nil,
                onOpenFolder: nil
            )
        }
        .frame(width: Theme.Size.historyPanel.width, height: Theme.Size.historyPanel.height)
        .floatingSurface(cornerRadius: Theme.Radius.dialog, showsBorder: false)
    }
}
