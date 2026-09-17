import CoreGraphics
import Testing
@testable import Jietu

/// 自动滚动的参数（步长 = 选区内高的 8%，夹在 40...120：步子细一半，滚动看着顺、重叠更多）。
///
/// @author ixxxxoooo
@Suite("自动滚动")
struct AutoScrollTests {
    @Test("步长是选区内高的 8%")
    func stepIsEightPercent() {
        #expect(AutoScroller.stepPoints(forHeight: 600) == 48)
        #expect(AutoScroller.stepPoints(forHeight: 1000) == 80)
    }

    @Test("过矮 / 过高的选区会被夹到 40...120")
    func stepIsClamped() {
        // 200 * 0.08 = 16 → 夹到下限。
        #expect(AutoScroller.stepPoints(forHeight: 200) == 40)
        // 4000 * 0.08 = 320 → 夹到上限。
        #expect(AutoScroller.stepPoints(forHeight: 4000) == 120)
        #expect(AutoScroller.stepPoints(forHeight: 0) == 40)
    }

    @Test("自动滚动：光标在选区里才滚，移出即暂停")
    func autoScrollOnlyWhileCursorInsideRegion() {
        let region = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(ScrollingCaptureSession.shouldScroll(cursor: CGPoint(x: 200, y: 150), region: region))
        // 移出去（下方 / 左侧 / 上方）都算出去。
        #expect(!ScrollingCaptureSession.shouldScroll(cursor: CGPoint(x: 200, y: 360), region: region))
        #expect(!ScrollingCaptureSession.shouldScroll(cursor: CGPoint(x: 20, y: 150), region: region))
        #expect(!ScrollingCaptureSession.shouldScroll(cursor: CGPoint(x: 200, y: 40), region: region))
    }
}
