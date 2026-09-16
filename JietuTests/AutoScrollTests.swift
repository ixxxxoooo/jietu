import CoreGraphics
import Testing
@testable import Jietu

/// 自动滚动的参数（照 capcap：步长 = 选区内高的 15%，夹在 60...180）。
///
/// @author ixxxxoooo
@Suite("自动滚动")
struct AutoScrollTests {
    @Test("步长是选区内高的 15%")
    func stepIsFifteenPercent() {
        #expect(AutoScroller.stepPoints(forHeight: 600) == 90)
        #expect(AutoScroller.stepPoints(forHeight: 1000) == 150)
    }

    @Test("过矮 / 过高的选区会被夹到 60...180")
    func stepIsClamped() {
        // 200 * 0.15 = 30 → 夹到下限。
        #expect(AutoScroller.stepPoints(forHeight: 200) == 60)
        // 4000 * 0.15 = 600 → 夹到上限。
        #expect(AutoScroller.stepPoints(forHeight: 4000) == 180)
        #expect(AutoScroller.stepPoints(forHeight: 0) == 60)
    }
}
