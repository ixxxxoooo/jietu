import AppKit
import Testing
@testable import Jietu

/// 「最近截图」卡片上那行时间：日期 + 时间。
///
/// @author ixxxxoooo
@Suite("最近截图卡片的日期")
struct HistoryCardTests {
    /// 固定一个「现在」：2026-09-18 14:00（本地时区）。
    private func now() -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 18
        components.hour = 14
        components.minute = 0
        components.second = 0
        return Calendar.current.date(from: components)!
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 2, _ minute: Int = 17, _ second: Int = 6
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components)!
    }

    @Test("今天 / 昨天用相对说法，带着时分秒")
    func todayAndYesterday() {
        #expect(HistoryItem.timestampText(for: date(2026, 9, 18), now: now()) == "今天 02:17:06")
        #expect(HistoryItem.timestampText(for: date(2026, 9, 17), now: now()) == "昨天 02:17:06")
    }

    @Test("今年内的写月日——只有时间的话分不清是哪天的")
    func sameYearShowsMonthAndDay() {
        #expect(HistoryItem.timestampText(for: date(2026, 9, 1), now: now()) == "9月1日 02:17:06")
        #expect(HistoryItem.timestampText(for: date(2026, 1, 31), now: now()) == "1月31日 02:17:06")
    }

    @Test("跨年的带上年份")
    func otherYearShowsYear() {
        #expect(
            HistoryItem.timestampText(for: date(2025, 12, 31), now: now()) == "2025年12月31日 02:17:06"
        )
    }
}

/// 卡片右下角那排快捷动作：谁该出现、谁不该。
///
/// @author ixxxxoooo
@Suite("最近截图卡片的快捷动作")
struct HistoryQuickActionTests {
    private func imageItem(url: URL? = URL(fileURLWithPath: "/tmp/jietu-test-shot.png")) -> HistoryItem {
        HistoryItem(
            id: "shot", date: Date(), image: NSImage(size: NSSize(width: 40, height: 30)),
            url: url, cgImage: nil
        )
    }

    private func videoItem() -> HistoryItem {
        HistoryItem(
            id: "movie", date: Date(), image: NSImage(size: NSSize(width: 40, height: 30)),
            url: URL(fileURLWithPath: "/tmp/jietu-test-movie.mp4"), cgImage: nil,
            videoURL: URL(fileURLWithPath: "/tmp/jietu-test-movie.mp4")
        )
    }

    @Test("图片卡片有「钉图」，顺序是 复制 → 钉图 → 访达 → 编辑")
    func imageCardOffersPin() {
        let actions = imageItem().quickActions(canCopy: true, canPin: true, canReveal: true)
        #expect(actions == [.copy, .pin, .reveal, .edit], "实际 \(actions)")
        #expect(actions.first(where: { $0 == .pin })?.title == "钉图")
    }

    @Test("录屏卡片不给「复制位图」「钉图」——那是 mp4，位图动作没意义")
    func videoCardHasNoImageActions() {
        let actions = videoItem().quickActions(canCopy: true, canPin: true, canReveal: true)
        #expect(!actions.contains(.copy))
        #expect(!actions.contains(.pin), "mp4 钉不了")
        #expect(actions == [.reveal, .edit], "实际 \(actions)")
    }

    @Test("外面没接的能力不露按钮（比如菜单没给 onPin 就没有钉图）")
    func capabilitiesGateTheButtons() {
        let item = imageItem()
        #expect(!item.quickActions(canCopy: true, canPin: false, canReveal: true).contains(.pin))
        #expect(!item.quickActions(canCopy: false, canPin: true, canReveal: true).contains(.copy))
        #expect(!item.quickActions(canCopy: true, canPin: true, canReveal: false).contains(.reveal))
        #expect(
            item.quickActions(canCopy: false, canPin: false, canReveal: false) == [.edit],
            "「编辑」不依赖外面接没接"
        )
    }

    @Test("钉图 / 复制取的是整张原图：磁盘上的原图优先于列表里的图")
    func resolvedImagePrefersTheFileOnDisk() throws {
        // 会话内的位图：直接用它。
        let bitmap = TestImage.solidColor(width: 12, height: 7, r: 10, g: 20, b: 30)
        let inSession = HistoryItem(id: "s", date: Date(), image: nil, url: nil, cgImage: bitmap)
        #expect(inSession.resolvedCGImage?.width == 12)

        // 只有文件：从文件读原图（40×30），而不是拿列表里那张 4×3 的缩略图。
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jietu-history-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")
        let full = TestImage.solidColor(width: 40, height: 30, r: 200, g: 100, b: 50)
        let rep = NSBitmapImageRep(cgImage: full)
        try rep.representation(using: .png, properties: [:])!.write(to: file)

        let fromFile = HistoryItem(
            id: "f", date: Date(),
            image: NSImage(size: NSSize(width: 4, height: 3)), url: file, cgImage: nil
        )
        #expect(fromFile.resolvedCGImage?.width == 40, "要从文件读原图")
        #expect(fromFile.resolvedCGImage?.height == 30)
    }
}
