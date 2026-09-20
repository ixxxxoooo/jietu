import AppKit
import Foundation
import Testing
@testable import Jietu

/// 拖拽授权卡片的热区测试。
///
/// 卡片是「把 App 拖进系统设置那栏」唯一的抓手，热区错位就等于拖不动——
/// 而 `hitTest(_:)` 的坐标系是最容易写错的一处（详见用例里那条注释）。
///
/// @author ixxxxoooo
@Suite("拖拽授权卡片")
@MainActor
struct AppBundleDragCardTests {
    private func makeCard(inContainerWithOffset offset: CGPoint) -> (
        container: NSView, card: AppBundleDragSourceView
    ) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let card = AppBundleDragSourceView(url: URL(fileURLWithPath: "/Applications/Jietu.app"))
        // 故意给一个非零起点：SwiftUI 的容器里卡片就落在这样的位置上。
        card.frame = NSRect(x: offset.x, y: offset.y, width: 300, height: 56)
        container.addSubview(card)
        return (container, card)
    }

    /// `hitTest(_:)` 收到的是**父视图坐标系**里的点，不是自己的 bounds。
    /// 直接拿 bounds 比，只在卡片恰好落在父视图原点时才碰巧对；一旦父视图给了偏移，
    /// 热区就整体挪走——用户按在卡片上也起不了拖拽。
    @Test("卡片热区跟着自身 frame 走，不受父视图偏移影响")
    func hitTestUsesSuperviewCoordinates() {
        let (_, card) = makeCard(inContainerWithOffset: CGPoint(x: 24, y: 60))

        // 卡片正中（按父视图坐标给出）命中卡片自己。
        #expect(card.hitTest(NSPoint(x: card.frame.midX, y: card.frame.midY)) === card)
        // 卡片左上角内侧一点点也命中。
        #expect(card.hitTest(NSPoint(x: card.frame.minX + 1, y: card.frame.minY + 1)) === card)
        // 卡片外沿之外不命中（内含）。
        #expect(card.hitTest(NSPoint(x: card.frame.maxX + 1, y: card.frame.midY)) == nil)
        #expect(card.hitTest(NSPoint(x: card.frame.midX, y: card.frame.maxY + 1)) == nil)
    }

    /// 卡片贴着父视图原点时（偏移为零）也要命中——这是原来那条写法唯一对的情形，
    /// 修完之后不能反过来把它弄坏。
    @Test("卡片落在父视图原点时同样命中")
    func hitTestAtOrigin() {
        let (_, card) = makeCard(inContainerWithOffset: .zero)
        #expect(card.hitTest(NSPoint(x: 10, y: 10)) === card)
        #expect(card.hitTest(NSPoint(x: -1, y: 10)) == nil)
    }

    /// 还没进父视图（布局前）时报「没命中」，而不是拿窗口坐标当 bounds 比。
    @Test("没有父视图时不命中")
    func hitTestWithoutSuperview() {
        let card = AppBundleDragSourceView(url: URL(fileURLWithPath: "/Applications/Jietu.app"))
        card.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        #expect(card.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }
}
