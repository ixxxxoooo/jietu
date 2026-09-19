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

    // MARK: - 补充：步长边界表驱动测试

    @Test(
        "步长边界表驱动",
        arguments: [
            (height: 0.0, expected: 40),     // 零高度 → 下限
            (height: 100.0, expected: 40),   // 100 * 0.08 = 8 → 下限
            (height: 499.0, expected: 40),   // 499 * 0.08 ≈ 39.9 → 下限
            (height: 500.0, expected: 40),   // 500 * 0.08 = 40 → 刚好下限
            (height: 501.0, expected: 40),   // 501 * 0.08 ≈ 40.08 → 40
            (height: 600.0, expected: 48),   // 600 * 0.08 = 48
            (height: 750.0, expected: 60),   // 750 * 0.08 = 60
            (height: 1000.0, expected: 80),  // 1000 * 0.08 = 80
            (height: 1500.0, expected: 120), // 1500 * 0.08 = 120 → 刚好上限
            (height: 1501.0, expected: 120), // → 上限
            (height: 2000.0, expected: 120), // → 上限
            (height: 4000.0, expected: 120), // → 上限
            (height: 10000.0, expected: 120), // 极端大值 → 上限
        ] as [(height: Double, expected: Int)]
    )
    func stepBoundaryTable(height: Double, expected: Int) {
        #expect(
            AutoScroller.stepPoints(forHeight: CGFloat(height)) == expected,
            "height=\(height) 应得步长 \(expected)"
        )
    }

    @Test("负高度被夹到下限")
    func negativeHeightClamped() {
        #expect(AutoScroller.stepPoints(forHeight: -100) == 40)
    }

    @Test("光标在选区左上角（minX,minY）算在内，右下边界（maxX,maxY）不算")
    func cursorOnBorderBehavior() {
        let region = CGRect(x: 100, y: 100, width: 300, height: 200)
        // CGRect.contains 的语义是 minX <= x < maxX，minY <= y < maxY
        #expect(ScrollingCaptureSession.shouldScroll(cursor: CGPoint(x: 100, y: 100), region: region), "左下角在内")
        #expect(!ScrollingCaptureSession.shouldScroll(cursor: CGPoint(x: 400, y: 300), region: region), "右上角（maxX,maxY）不在内")
        // 中心点肯定在内
        #expect(ScrollingCaptureSession.shouldScroll(cursor: CGPoint(x: 250, y: 200), region: region), "中心在内")
    }
}
