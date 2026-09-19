import AppKit

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
    /// 录屏条目：能被播放器打开的视频本体（截图条目为 nil）。
    var videoURL: URL?
    /// 录屏时长（秒），卡片上那枚「▶ 0:12」角标用它。
    var videoDuration: TimeInterval?

    /// 这是不是一段录屏。
    var isVideo: Bool { videoURL != nil }

    /// 「复制位图 / 钉图」这类**图像动作**给不给：录屏条目只有 mp4，位图动作对它没意义
    /// （文件本身可以在访达里拿，也可以直接拖出去）。
    var supportsImageActions: Bool { !isVideo }

    /// 快捷动作要用的**整张**位图：会话内那份位图 → 磁盘上的原图 → 列表里的图。
    var resolvedCGImage: CGImage? {
        if let cgImage { return cgImage }
        if let url, let loaded = NSImage(contentsOf: url),
            let cg = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            return cg
        }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// 卡片快捷操作栏里显示哪些动作（顺序固定：图像动作 → 访达 → 编辑）。
    ///
    /// `can*` 是外面**接没接**对应回调：没这个能力就不露那个按钮（托盘历史面板就不传 `canClear` 那类）。
    func quickActions(canCopy: Bool, canPin: Bool, canReveal: Bool) -> [HistoryQuickAction] {
        var actions: [HistoryQuickAction] = []
        if supportsImageActions {
            if canCopy { actions.append(.copy) }
            if canPin { actions.append(.pin) }
        }
        if canReveal, url != nil { actions.append(.reveal) }
        actions.append(.edit)
        return actions
    }

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
