import AppKit
import SwiftUI

/// 一条历史记录。
///
/// @author ixxxxoooo
struct HistoryItem: Identifiable {
    let id: String
    let url: URL
    let date: Date
    let image: NSImage?
}

/// 托盘历史面板：按时间列出最近的截图缩略图。
///
/// @author ixxxxoooo
struct HistoryView: View {
    let items: [HistoryItem]
    var onSelect: (URL) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("截图历史", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("完成") { onClose() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if items.isEmpty {
                Spacer()
                Text("还没有截图")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(items) { item in
                            itemView(item)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 320, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func itemView(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.formatter.string(from: item.date))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            if let image = item.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { onSelect(item.url) }
                    .help("点击在编辑器中打开")
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 120)
                    .overlay(Text("无法读取").font(.system(size: 11)).foregroundStyle(.secondary))
            }
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}
