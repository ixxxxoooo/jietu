import AppKit
import Foundation

/// 「最近截图」的一条记录。
///
/// 两种条目：
/// - **截图**：`historyPath` 指向历史目录里的原图 PNG；
/// - **录屏**：`historyPath` 指向历史目录里的**封面缩略图**，视频本体在 `videoPath`
///   （用户保存目录里那个 mp4）——本体动辄几十上百 MB，复制进历史等于占用翻倍，
///   所以只记路径，用户挪走它就点不开了（和截图 `savedPath` 一个规矩）。
///
/// @author ixxxxoooo
struct HistoryEntry: Codable, Identifiable, Hashable {
    let id: String
    let date: Date
    /// App 自己历史目录里的那一份（永远在）：重启后靠它显示缩略图、复制原图。
    let historyPath: String
    /// 用户「保存到磁盘」/ 另存为得到的那一份（可能没有）：打开、在访达中显示优先用它。
    var savedPath: String?
    /// 录屏：视频本体在磁盘上的路径。截图条目为 nil。
    var videoPath: String?
    /// 录屏时长（秒），卡片与菜单上显示。
    var videoDuration: TimeInterval?

    var historyURL: URL { URL(fileURLWithPath: historyPath) }
    var savedURL: URL? { savedPath.map { URL(fileURLWithPath: $0) } }
    /// 对外用哪个：有用户自己那份就用它（打开 / 在访达中显示都该落到用户的文件上）。
    var displayURL: URL { savedURL ?? historyURL }
    /// 这是不是一段录屏。
    var isVideo: Bool { videoPath != nil }
    /// 录屏本体（能被播放器打开的那个）。
    var videoURL: URL? { videoPath.map { URL(fileURLWithPath: $0) } }
    /// 点开时该给谁：录屏给视频本体，截图给用户那份（没有就历史那份）。
    var openURL: URL { videoURL ?? displayURL }
}

/// 「最近截图」的**落盘**历史。
///
/// 为什么需要它：截图默认只进剪贴板（`saveToDisk` 默认关），而「最近截图」以前列的是
/// **磁盘上的文件**（`settings.recentCaptureURLs`）——不开那个开关时，重启后列表必然是空的。
/// 现在每张截图都在 App 自己的历史目录里留一份 PNG + 一份 JSON 索引，重启照样有数据。
///
/// - 目录：`~/Library/Application Support/<bundle id>/History`（Debug / Release 各一份，互不打扰）；
/// - 上限：条数 `maxEntries`、总体积 `maxBytes`，超了从最旧的开始丢（文件一起删）；
/// - 「清除记录」= 清空目录并删掉索引。
///
/// @author ixxxxoooo
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    /// 最多留多少条。
    static let maxEntries = 40
    /// 历史目录最多占多少字节（超了丢最旧的）。
    /// 截图是 PNG 一张几 MB，录屏 mp4 几十到几百 MB；2 GB 大约够放 40 张截图 + 若干录屏。
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024

    private let directory: URL
    private let indexURL: URL
    private(set) var entries: [HistoryEntry] = []

    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Jietu", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("JietuHistory")
        self.indexURL = self.directory.appendingPathComponent("index.json")
        load()
    }

    /// 记一张截图：先落盘，再进索引。
    ///
    /// 写不进（磁盘满 / 目录权限）就返回 nil——**不影响截图本身**：图还在剪贴板 / 浮窗里。
    @discardableResult
    func record(_ image: CGImage, date: Date = Date()) -> HistoryEntry? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let url = directory.appendingPathComponent("\(Self.fileStamp(date))-\(id.prefix(8)).png")
        guard let data = CaptureOutput.pngData(image), (try? data.write(to: url, options: .atomic)) != nil
        else { return nil }

        let entry = HistoryEntry(
            id: id, date: date, historyPath: Self.normalizedPath(url), savedPath: nil
        )
        entries.insert(entry, at: 0)
        prune()
        save()
        return entry
    }

    /// 用户把这张截图存到磁盘（自动保存或另存为）之后回填：打开 / 在访达中显示改用它。
    func attachSavedFile(_ url: URL, to id: String?) {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].savedPath = Self.normalizedPath(url)
        save()
    }

    /// 记一段录屏：把临时 mp4 搬进历史目录（和截图一样「先安顿好」），封面另存一份。
    ///
    /// 核心思路：**录屏的主副本住在历史目录里**，用户的保存目录只是「另存」的副本。
    /// 临时文件在 /tmp 里，不搬的话重启就没了——截图也是同样的做法。
    @discardableResult
    func recordVideo(
        temporaryURL: URL, cover: CGImage, duration: TimeInterval, date: Date = Date()
    ) -> HistoryEntry? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let stamp = Self.fileStamp(date)

        // 搬视频到历史目录（主副本）
        let videoDestination = directory.appendingPathComponent("\(stamp)-\(id.prefix(8)).mp4")
        guard (try? FileManager.default.moveItem(at: temporaryURL, to: videoDestination)) != nil
        else { return nil }

        // 存封面缩略图
        let coverURL = directory.appendingPathComponent("\(stamp)-\(id.prefix(8))-cover.png")
        guard let data = CaptureOutput.pngData(cover),
            (try? data.write(to: coverURL, options: .atomic)) != nil
        else { return nil }

        let entry = HistoryEntry(
            id: id, date: date, historyPath: Self.normalizedPath(coverURL),
            savedPath: nil,
            videoPath: Self.normalizedPath(videoDestination),
            videoDuration: duration
        )
        entries.insert(entry, at: 0)
        prune()
        save()
        return entry
    }

    /// 用户把这段录屏「另存为」到磁盘后回填（打开 / 在访达中显示改用它）。
    func attachSavedVideo(_ savedURL: URL, sourceVideoURL: URL) {
        let normalizedVideo = Self.normalizedPath(sourceVideoURL)
        guard let index = entries.firstIndex(where: { $0.videoPath == normalizedVideo }) else { return }
        entries[index].savedPath = Self.normalizedPath(savedURL)
        save()
    }

    /// 录屏封面后补：先用占位图把条目**同步**记上（「东西在」这件事一刻都不能等），
    /// 真封面取到后再换掉它。
    func updateCover(_ cover: CGImage, duration: TimeInterval, for id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
            let data = CaptureOutput.pngData(cover)
        else { return }
        let url = entries[index].historyURL
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        if duration > 0 { entries[index].videoDuration = duration }
        save()
        // 缩略图缓存要失效，否则菜单里还挂着那张占位图（录屏收工是低频操作，整清即可）。
        HistoryThumbnailCache.shared.clear()
    }

    /// 自检用：历史目录（拿它另开一个实例，模拟「重启后再读一遍」）。
    var directoryForTesting: URL { directory }

    /// 最新一条的 id（刚截完图、落盘还没回来时用它回填）。
    var latestID: String? { entries.first?.id }

    /// 「清除记录」：文件与索引一起清掉。
    func removeAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: directory)
        HistoryThumbnailCache.shared.clear()
    }

    /// 读原图（复制用）。历史那份永远是 PNG，直接解。
    func image(for entry: HistoryEntry) -> CGImage? {
        NSImage(contentsOf: entry.displayURL)?.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        )
    }

    // MARK: - 索引

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
            let stored = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        // 历史目录被谁清掉过：索引里那些找不到文件的条目直接丢掉。
        // 录屏条目还要看**视频本体**在不在（历史里只有封面）——本体被删/挪走就点不开了。
        let fileManager = FileManager.default
        entries = stored.filter { entry in
            guard fileManager.fileExists(atPath: entry.historyPath) else { return false }
            guard let videoPath = entry.videoPath else { return true }
            return fileManager.fileExists(atPath: videoPath)
        }
        if entries.count != stored.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 超条数 / 超体积：从最旧的开始丢，文件一起删。
    private func prune() {
        var dropped: [HistoryEntry] = []
        if entries.count > Self.maxEntries {
            dropped += entries[Self.maxEntries...]
            entries = Array(entries.prefix(Self.maxEntries))
        }
        var total = entries.reduce(Int64(0)) { $0 + totalSize(of: $1) }
        while total > Self.maxBytes, let last = entries.last {
            dropped.append(last)
            entries.removeLast()
            total -= totalSize(of: last)
        }
        for entry in dropped {
            try? FileManager.default.removeItem(at: entry.historyURL)
            // 录屏条目：视频主副本也在历史目录里，一起删。
            if let videoPath = entry.videoPath {
                try? FileManager.default.removeItem(atPath: videoPath)
            }
        }
    }

    /// 条目在历史目录里占的总大小（封面 + 视频）。
    private func totalSize(of entry: HistoryEntry) -> Int64 {
        var total = size(of: entry.historyURL)
        if let videoPath = entry.videoPath {
            total += size(of: URL(fileURLWithPath: videoPath))
        }
        return total
    }

    private func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// 存进索引的路径统一写法。
    ///
    /// macOS 上 `/var` 与 `/private/var` 指向同一个地方，两个 API 给出的写法还不一样
    /// （实测自检里 `moveFile` 给的带 `/private`、目录枚举给的不带）。不归一的话
    /// **同一个文件会被当成两个**：去重失效、菜单里出现重复条目、回填 `savedPath` 找不到人。
    private static func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// 文件名里的时间戳：`20260918-020304`，光看目录也知道什么时候截的。
    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
