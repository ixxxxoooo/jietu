import CoreGraphics
import Testing
@testable import Jietu

/// 冻结屏幕的比例与 point→pixel 换算。
///
/// @author ixxxxoooo
@Suite("屏幕快照换算")
struct DisplaySnapshotTests {
    private func makeSnapshot(
        imageWidth: Int,
        imageHeight: Int,
        pointWidth: CGFloat,
        pointHeight: CGFloat
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight),
            nominalScaleFactor: 2,
            image: TestImage.horizontalBands(
                width: imageWidth,
                height: imageHeight,
                rows: [(0, 0, 0)]
            )
        )
    }

    @Test("effectiveScale 用实际像素宽度除以逻辑宽度")
    func effectiveScale() {
        let snapshot = makeSnapshot(
            imageWidth: 200,
            imageHeight: 150,
            pointWidth: 100,
            pointHeight: 75
        )
        #expect(abs(snapshot.effectiveScale - 2) < 0.0001)
    }

    @Test("pixelPoint 将 local（原点左下）翻成像素（原点左上）")
    func pixelPointFlipsY() {
        let snapshot = makeSnapshot(
            imageWidth: 200,
            imageHeight: 150,
            pointWidth: 100,
            pointHeight: 75
        )
        let pixel = snapshot.pixelPoint(fromLocalPoint: CGPoint(x: 10, y: 20))
        #expect(pixel.x == 20)
        #expect(pixel.y == 110)
    }
}
