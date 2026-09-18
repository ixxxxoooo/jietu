import AppKit
import SwiftUI

/// 一条历史记录。
///
/// @author ixxxxoooo
struct HistoryItem: Identifiable, Sendable {
    let id: String
    let date: Date
    let image: NSImage?
    /// 已保存到磁盘的文件（可选）。
    let url: URL?
    /// 会话内截图的原始位图（可选）。
    let cgImage: CGImage?

    var resolutionDescription: String? {
        if let cgImage {
            return "\(cgImage.width) × \(cgImage.height)"
        }
        if let image {
            let reps = image.representations
            if let first = reps.first, first.pixelsWide > 0, first.pixelsHigh > 0 {
                return "\(first.pixelsWide) × \(first.pixelsHigh)"
            }
            if image.size.width > 0 {
                return "\(Int(image.size.width)) × \(Int(image.size.height))"
            }
        }
        return nil
    }

    var fileSizeDescription: String? {
        guard let url, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var timeFormatted: String { Self.timestampText(for: date) }

    /// 卡片上那行时间：**日期 + 时间**。
    ///
    /// 只写时分秒的话，跨天翻看就分不清是哪天的（之前就是这样）。规矩照 Finder 那套：
    /// 今天 / 昨天用相对说法，今年内写「M月d日」，跨年再带上年份。
    ///
    /// 纯函数（`now` 可注入），单测直接钉几种情况。
    static func timestampText(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let time = Self.timeOnlyFormatter.string(from: date)
        // 「今天 / 昨天」按传进来的 `now` 判，别用 `isDateInToday`：那个看的是**真实时钟**，
        // 于是这个「now 可注入」的纯函数其实测不出今天 / 昨天（单测在午夜前后会翻车）。
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 " + time
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "昨天 " + time
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日 "
                + time
        }
        return "\(calendar.component(.year, from: date))年"
            + "\(calendar.component(.month, from: date))月"
            + "\(calendar.component(.day, from: date))日 " + time
    }

    private static let timeOnlyFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm:ss"
        return df
    }()
}

/// 历史缩略图轻量内存缓存，加速菜单展开帧率。
final class HistoryThumbnailCache: @unchecked Sendable {
    static let shared = HistoryThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    func clear() {
        cache.removeAllObjects()
    }
}

/// 单张截图预览卡片。
struct HistoryCardView: View {
    let item: HistoryItem
    var onSelect: (HistoryItem) -> Void
    var onRevealInFinder: ((HistoryItem) -> Void)?
    var onCopy: ((HistoryItem) -> Void)?

    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            // 标头信息行：拍摄时间 + 分辨率或大小
            HStack(spacing: 6) {
                Text(item.timeFormatted)
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Spacer(minLength: 4)

                if let info = item.resolutionDescription ?? item.fileSizeDescription {
                    Text(info)
                        .font(Theme.Typography.numeric)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 2)

            // 缩略图视窗（等比适配，深色衬底防反光）
            ZStack {
                shape
                    .fill(Theme.Colors.iconPlaceholder)

                if let image = item.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 110)
                        .clipShape(shape)
                } else {
                    Text("无法读取")
                        .font(Theme.Typography.rowSubtitle)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .overlay(
                shape.strokeBorder(
                    isHovered ? Theme.Colors.accent.opacity(0.4) : Theme.Colors.cardStroke,
                    lineWidth: Theme.Size.hairline
                )
            )

            // 快捷操作栏
            HStack(spacing: 8) {
                Spacer()

                if onCopy != nil {
                    Button {
                        onCopy?(item)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "已复制" : "复制")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(copied ? Theme.Colors.success : Theme.Colors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("复制图像到剪贴板")
                }

                if let onRevealInFinder, item.url != nil {
                    Button {
                        onRevealInFinder(item)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                            Text("访达")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("在访达中显示")
                }

                Button {
                    onSelect(item)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "pencil.tip.crop.circle")
                        Text("编辑")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.Colors.accent.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .help("在标注编辑器中打开")
            }
            .opacity(isHovered ? 1.0 : 0.75)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.15), value: copied)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.08) : Theme.Colors.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(
                    isHovered ? Theme.Colors.accent.opacity(0.5) : Theme.Colors.cardStroke,
                    lineWidth: Theme.Size.hairline
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(item)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// 右侧子菜单卡片预览视图：合并了原“截图历史”的大图预览与“最近截图”入口。
struct RecentHistoryMenuView: View {
    let items: [HistoryItem]
    var onSelect: (HistoryItem) -> Void
    var onRevealInFinder: ((HistoryItem) -> Void)?
    var onCopy: ((HistoryItem) -> Void)?
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

            Text("最近截图")
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
                .help("打开截图文件夹")
            }

            if let onClear, !items.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("清除所有记录")
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
                Text("暂无最近截图")
                    .font(Theme.Typography.rowSubtitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text("截图后会自动展示在这里")
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
                            onCopy: onCopy
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
                Text("截图历史")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer(minLength: Theme.Spacing.md)
                GlassButton(title: "完成", role: .cancel, action: onClose)
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
                    if let cg = item.cgImage {
                        CaptureOutput.copyToPasteboard(cg)
                    } else if let img = item.image,
                              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        CaptureOutput.copyToPasteboard(cg)
                    }
                },
                onClear: nil,
                onOpenFolder: nil
            )
        }
        .frame(width: Theme.Size.historyPanel.width, height: Theme.Size.historyPanel.height)
        .floatingSurface(cornerRadius: Theme.Radius.dialog, showsBorder: false)
    }
}

