import AppKit
import Testing
@testable import Jietu

/// 坐标系换算是截图准确性的地基，这里只验证可量化的不变量。
///
/// @author ixxxxoooo
@Suite("坐标换算")
struct DisplayGeometryTests {
    @Test("local→cg→local 往返一致")
    func cgRoundTrip() throws {
        let screen = try #require(NSScreen.screens.first)
        let local = CGPoint(x: 123, y: 45)
        let cg = DisplayGeometry.cgPoint(fromLocal: local, screen: screen)
        let back = DisplayGeometry.localPoint(fromCG: cg, screen: screen)
        #expect(abs(back.x - local.x) < 0.001)
        #expect(abs(back.y - local.y) < 0.001)
    }

    @Test("cg 顶边矩形映射到 local 的顶边")
    func localRectFlipsY() throws {
        let screen = try #require(DisplayGeometry.referenceScreen)
        // cg 原点在左上，y=0 即主屏顶边。
        let local = DisplayGeometry.localRect(
            fromCGRect: CGRect(x: 0, y: 0, width: 100, height: 50),
            screen: screen
        )
        #expect(local.width == 100)
        #expect(local.height == 50)
        #expect(abs(local.minX) < 0.001)
        #expect(abs(local.maxY - screen.frame.height) < 0.001)
    }
}
