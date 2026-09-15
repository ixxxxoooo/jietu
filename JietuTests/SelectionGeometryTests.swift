import CoreGraphics
import Testing
@testable import Jietu

/// `SelectionGeometry` 的纯函数行为验证。
///
/// @author ixxxxoooo
@Suite("选区几何")
struct SelectionGeometryTests {
    @Test("由锚点到当前点生成规范化矩形（支持四个方向）")
    func rectNormalizes() {
        let rect = SelectionGeometry.rect(
            from: CGPoint(x: 100, y: 200),
            to: CGPoint(x: 40, y: 50)
        )
        #expect(rect == CGRect(x: 40, y: 50, width: 60, height: 150))
    }

    @Test("Shift 锁正方形，边长取两轴较大者")
    func selectionRectSquare() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        let rect = SelectionGeometry.selectionRect(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 200, y: 60),
            clampTo: bounds,
            square: true
        )
        #expect(rect.width == 190)
        #expect(rect.height == 190)
        #expect(bounds.contains(rect))
    }

    @Test("调整角 handle 到目标点")
    func resizedToPoint() {
        let original = CGRect(x: 100, y: 100, width: 200, height: 200)
        let rect = SelectionGeometry.resized(
            original,
            handle: .topRight,
            to: CGPoint(x: 400, y: 450),
            clampTo: CGRect(x: 0, y: 0, width: 500, height: 500),
            lockAspect: false
        )
        #expect(rect == CGRect(x: 100, y: 100, width: 300, height: 350))
    }

    @Test("调整结果被裁进边界")
    func resizedClampsToBounds() {
        let original = CGRect(x: 100, y: 100, width: 200, height: 200)
        let rect = SelectionGeometry.resized(
            original,
            handle: .topRight,
            to: CGPoint(x: 900, y: 900),
            clampTo: CGRect(x: 0, y: 0, width: 500, height: 500),
            lockAspect: false
        )
        #expect(rect == CGRect(x: 100, y: 100, width: 400, height: 400))
    }

    @Test("调整后各边不小于最小边长")
    func resizedEnforcesMinimumSide() {
        let original = CGRect(x: 100, y: 100, width: 200, height: 200)
        let rect = SelectionGeometry.resized(
            original,
            handle: .right,
            to: CGPoint(x: 101, y: 200),
            clampTo: CGRect(x: 0, y: 0, width: 500, height: 500),
            lockAspect: false
        )
        #expect(rect.width >= SelectionGeometry.minimumSide)
        #expect(rect.minX == 100)
    }

    @Test("平移选区并夹在边界内")
    func movedClampsToBounds() {
        let original = CGRect(x: 100, y: 100, width: 100, height: 100)
        let rect = SelectionGeometry.moved(
            original,
            by: CGSize(width: 1000, height: 0),
            clampTo: CGRect(x: 0, y: 0, width: 500, height: 500)
        )
        #expect(rect.origin == CGPoint(x: 400, y: 100))
    }

    @Test("命中左下角 handle")
    func handleHitTest() {
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        let handle = SelectionGeometry.handle(
            at: CGPoint(x: 100, y: 100),
            in: rect,
            tolerance: 9
        )
        #expect(handle == .bottomLeft)
    }

    @Test("远离所有 handle 时命中为空")
    func handleMiss() {
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        let handle = SelectionGeometry.handle(
            at: CGPoint(x: 150, y: 150),
            in: rect,
            tolerance: 9
        )
        #expect(handle == nil)
    }
}
