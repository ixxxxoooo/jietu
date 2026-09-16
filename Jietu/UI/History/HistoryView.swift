import AppKit
import SwiftUI

/// 一条历史记录。
///
/// @author ixxxxoooo
struct HistoryItem: Identifiable {
    let id: String
    let date: Date
    let image: NSImage?
    /// 已保存到磁盘的文件（可选）。
    let url: URL?
    /// 会话内截图的原始位图（可选）。
    let cgImage: CGImage?
}

/// 托盘历史面板：按时间列出最近的截图缩略图。
///
/// 浮窗表面走设计系统——磨砂 + 墨色 scrim + `Radius.dialog`，
/// 头部次级墨色，缩略图 `Radius.thumbnail` + 细描边。
///
/// @author ixxxxoooo
struct HistoryView: View {
    let items: [HistoryItem]
    var onSelect: (HistoryItem) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: Theme.Size.hairline)
            content
        }
        .frame(width: Theme.Size.historyPanel.width, height: Theme.Size.historyPanel.height)
        .floatingSurface(cornerRadius: Theme.Radius.dialog, showsBorder: false)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "clock.arrow.circlepath")
                .font(Theme.Typography.bar)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("截图历史")
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(Theme.Colors.textPrimary)
            Spacer(minLength: Theme.Spacing.md)
            GlassButton(title: "完成", role: .cancel, action: onClose)
        }
        .padding(.leading, Theme.Spacing.xl)
        .padding(.trailing, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
    }

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            Text("还没有截图")
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    ForEach(items) { item in
                        itemView(item)
                    }
                }
                .padding(Theme.Spacing.xl)
            }
        }
    }

    private func itemView(_ item: HistoryItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous)
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(Self.formatter.string(from: item.date))
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.Colors.textSecondary)

            if let image = item.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Theme.Colors.border, lineWidth: Theme.Size.hairline))
                    .contentShape(shape)
                    .onTapGesture { onSelect(item) }
                    .help("点击在编辑器中打开")
            } else {
                shape
                    .fill(Theme.Colors.iconPlaceholder)
                    .frame(height: 120)
                    .overlay(
                        Text("无法读取")
                            .font(Theme.Typography.rowSubtitle)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    )
            }
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}
