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

    @Test("local 矩形 → 全局 cg 矩形：以上边为基准，不能整体下移一个高度")
    func cgRectKeepsTopEdge() {
        let screen = NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let local = CGRect(x: 100, y: 200, width: 300, height: 150)
        let cg = DisplayGeometry.cgRect(fromLocal: local, screen: screen)

        // local 的上边（AppKit 里更高的 y）翻过来就是 cg 的上边。
        #expect(cg.minY == DisplayGeometry.referenceHeight - (screen.frame.minY + local.maxY))
        #expect(cg.minX == screen.frame.minX + local.minX)
        #expect(cg.size == local.size)

        // 翻回去要回到原处（往返一致）。
        let back = DisplayGeometry.localRect(fromCGRect: cg, screen: screen)
        #expect(abs(back.minX - local.minX) < 0.001)
        #expect(abs(back.minY - local.minY) < 0.001)
        #expect(abs(back.width - local.width) < 0.001)
        #expect(abs(back.height - local.height) < 0.001)

        // 直接拿 origin 翻（老写法）会整体下移一个高度——这条就是当时那个 bug。
        let wrong = CGRect(
            origin: DisplayGeometry.cgPoint(fromLocal: local.origin, screen: screen),
            size: local.size
        )
        #expect(wrong.minY != cg.minY)
        #expect(abs(wrong.minY - (cg.minY + local.height)) < 0.001)
    }
}
