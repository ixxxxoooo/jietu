import AVFoundation
import Testing
@testable import Jietu

/// 裁剪区间归整 + 时间文本（真正的导出由自检端到端验：直通导出依赖真文件）。
///
/// @author ixxxxoooo
@Suite("视频裁剪")
struct VideoTrimmerTests {

    @Test("正常区间原样保留")
    func keepsValidRange() throws {
        let range = try #require(TrimRange.clamp(start: 1, end: 5, duration: 10))
        #expect(range.start == 1)
        #expect(range.end == 5)
    }

    @Test("越界夹回 [0, duration]")
    func clampsToDuration() throws {
        let range = try #require(TrimRange.clamp(start: -3, end: 20, duration: 10))
        #expect(range.start == 0)
        #expect(range.end == 10)

        // 时长本身为 0（坏文件）：没有可导出的区间。
        #expect(TrimRange.clamp(start: 0, end: 5, duration: 0) == nil)
    }

    @Test("start 比 end 大时按顺序换回来（拖柄交叉不该报错）")
    func swapsReversedRange() throws {
        let range = try #require(TrimRange.clamp(start: 5, end: 1, duration: 10))
        #expect(range.start == 1)
        #expect(range.end == 5)
    }

    @Test("比最短长度还短的区间视为误操作")
    func rejectsTooShortRange() {
        #expect(TrimRange.clamp(start: 1, end: 1.05, duration: 10) == nil)
        #expect(TrimRange.clamp(start: 2, end: 2, duration: 10) == nil)
        // 正好等于最短长度：放行（边界上是可用的）。
        #expect(TrimRange.clamp(start: 2, end: 2.1, duration: 10) != nil)
    }

    @Test("裁剪界面的时间文本：精确到 0.1 秒")
    func timeText() {
        #expect(VideoTrimView.timeText(0) == "0:00.0")
        #expect(VideoTrimView.timeText(2.4) == "0:02.4")
        #expect(VideoTrimView.timeText(65.3) == "1:05.3")
        // 负数（播放头还没起来时）不能显示成 "-0:01.0"。
        #expect(VideoTrimView.timeText(-1) == "0:00.0")
    }
}
