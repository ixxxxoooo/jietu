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
