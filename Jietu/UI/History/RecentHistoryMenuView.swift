import AppKit
import SwiftUI

/// 右侧子菜单卡片预览视图：合并了原“截图历史”的大图预览与“最近截图”入口。
struct RecentHistoryMenuView: View {
    let items: [HistoryItem]
    var onSelect: (HistoryItem) -> Void
    var onRevealInFinder: ((HistoryItem) -> Void)?
    var onCopy: ((HistoryItem) -> Void)?
    var onPin: ((HistoryItem) -> Void)?
    var onClear: (() -> Void)?
    var onOpenFolder: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: Theme.Size.hairline)

            content
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.accent)

            Text(L10n.menuRecentHistory)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.textPrimary)

            if !items.isEmpty {
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.white.opacity(0.1))
                    )
            }

            Spacer()

            if let onOpenFolder {
                Button(action: onOpenFolder) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help(L10n.historyOpenFolder)
            }

            if let onClear, !items.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help(L10n.historyClearAll)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.Colors.textSecondary.opacity(0.6))
                Text(L10n.historyNoRecords)
                    .font(Theme.Typography.rowSubtitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(L10n.historyAutoDisplay)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 24)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        HistoryCardView(
                            item: item,
                            onSelect: onSelect,
                            onRevealInFinder: onRevealInFinder,
                            onCopy: onCopy,
                            onPin: onPin
                        )
                    }
                }
                .padding(8)
            }
        }
    }
}

/// 专为菜单项设计的 HostingView，支持首击响应与滚轮事件透传。
final class MenuHostingView<Content: View>: NSHostingView<Content> {
    private var scrollMonitor: Any?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startScrollMonitoring()
        } else {
            stopScrollMonitoring()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopScrollMonitoring()
        }
    }

    private func startScrollMonitoring() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window == window else { return event }
            let locInWindow = event.locationInWindow
            let locInView = self.convert(locInWindow, from: nil)
            if self.bounds.contains(locInView) {
                if let hit = self.hitTest(locInView) {
                    hit.scrollWheel(with: event)
                    return nil
                }
            }
            return event
        }
    }

    private func stopScrollMonitoring() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}
