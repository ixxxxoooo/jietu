import AppKit
import Foundation

/// 「最近截图」的一条记录。
///
/// @author ixxxxoooo
struct HistoryEntry: Codable, Identifiable, Hashable {
    let id: String
    let date: Date
    /// App 自己历史目录里的那一份（永远在）：重启后靠它显示缩略图、复制原图。
    let historyPath: String
    /// 用户「保存到磁盘」/ 另存为得到的那一份（可能没有）：打开、在访达中显示优先用它。
    var savedPath: String?

    var historyURL: URL { URL(fileURLWithPath: historyPath) }
    var savedURL: URL? { savedPath.map { URL(fileURLWithPath: $0) } }
    /// 对外用哪个：有用户自己那份就用它（打开 / 在访达中显示都该落到用户的文件上）。
    var displayURL: URL { savedURL ?? historyURL }
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
    /// 历史目录最多占多少字节（超了丢最旧的）。截图是 PNG，一屏 5K 也就几 MB，400MB 够留不少。
    static let maxBytes: Int64 = 400 * 1024 * 1024

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

        let entry = HistoryEntry(id: id, date: date, historyPath: url.path, savedPath: nil)
        entries.insert(entry, at: 0)
        prune()
        save()
        return entry
    }

    /// 用户把这张截图存到磁盘（自动保存或另存为）之后回填：打开 / 在访达中显示改用它。
    func attachSavedFile(_ url: URL, to id: String?) {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].savedPath = url.path
        save()
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
        let fileManager = FileManager.default
        entries = stored.filter { fileManager.fileExists(atPath: $0.historyPath) }
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
        var total = entries.reduce(Int64(0)) { $0 + size(of: $1.historyURL) }
        while total > Self.maxBytes, let last = entries.last {
            dropped.append(last)
            entries.removeLast()
            total -= size(of: last.historyURL)
        }
        for entry in dropped {
            try? FileManager.default.removeItem(at: entry.historyURL)
        }
    }

    private func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// 文件名里的时间戳：`20260918-020304`，光看目录也知道什么时候截的。
    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
