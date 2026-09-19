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

    // MARK: - 补充：referenceHeight 与副屏

    @Test("referenceHeight 大于零")
    func referenceHeightIsPositive() {
        #expect(DisplayGeometry.referenceHeight > 0, "必须有主屏高度才能做 Y 轴翻转")
    }

    @Test("referenceScreen 是原点在 (0,0) 的那块屏")
    func referenceScreenIsOriginScreen() throws {
        let ref = try #require(DisplayGeometry.referenceScreen)
        #expect(ref.frame.origin == .zero, "参考屏的原点应在 (0,0)")
    }

    @Test("flipY 翻转两次回到原处")
    func flipYRoundTrip() {
        let original = CGPoint(x: 42, y: 100)
        let flipped = DisplayGeometry.flipY(original)
        let back = DisplayGeometry.flipY(flipped)
        #expect(abs(back.x - original.x) < 0.001)
        #expect(abs(back.y - original.y) < 0.001)
    }

    @Test("flipY(0,0) → (0, referenceHeight)")
    func flipYOrigin() {
        let flipped = DisplayGeometry.flipY(.zero)
        #expect(flipped.x == 0)
        #expect(abs(flipped.y - DisplayGeometry.referenceHeight) < 0.001)
    }

    @Test("appKit→local→appKit 往返一致")
    func appKitLocalRoundTrip() throws {
        let screen = try #require(NSScreen.screens.first)
        let appKit = CGPoint(x: screen.frame.minX + 50, y: screen.frame.minY + 100)
        let local = DisplayGeometry.localPoint(fromAppKit: appKit, screen: screen)
        let back = DisplayGeometry.appKitPoint(fromLocal: local, screen: screen)
        #expect(abs(back.x - appKit.x) < 0.001)
        #expect(abs(back.y - appKit.y) < 0.001)
    }

    @Test("cgRect → localRect → cgRect 往返一致")
    func cgRectRoundTrip() throws {
        let screen = try #require(NSScreen.screens.first)
        let cg = CGRect(x: 50, y: 50, width: 200, height: 100)
        let local = DisplayGeometry.localRect(fromCGRect: cg, screen: screen)
        let back = DisplayGeometry.cgRect(fromLocal: local, screen: screen)
        #expect(abs(back.minX - cg.minX) < 0.001)
        #expect(abs(back.minY - cg.minY) < 0.001)
        #expect(abs(back.width - cg.width) < 0.001)
        #expect(abs(back.height - cg.height) < 0.001)
    }
}
