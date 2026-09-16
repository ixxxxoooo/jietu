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

    @Test("改选区后，标注按 imageDelta 平移仍钉在同一画面位置")
    func regionResizeImageDelta() {
        let scale: CGFloat = 2
        // 左 / 下边缘外扩（AppKit 坐标 y 向上，顶边是 maxY）。
        let before = CGRect(x: 100, y: 100, width: 200, height: 150)
        let after = CGRect(x: 80, y: 90, width: 240, height: 190)

        let delta = SelectionGeometry.imageDelta(from: before, to: after, scale: scale)
        #expect(delta.width == 40)   // (100 - 80) * 2：左边外扩，图像坐标变大
        #expect(delta.height == 60)  // (280 - 250) * 2：顶边上移，图像坐标变大

        // 固定一个画面点（视图坐标），它在两个选区里的图像坐标之差必须正好等于 delta。
        let viewPoint = CGPoint(x: 150, y: 160)
        func imagePoint(_ rect: CGRect) -> CGPoint {
            CGPoint(
                x: (viewPoint.x - rect.minX) * scale,
                y: (rect.maxY - viewPoint.y) * scale
            )
        }
        let beforeImage = imagePoint(before)
        let afterImage = imagePoint(after)
        #expect(abs((beforeImage.x + delta.width) - afterImage.x) < 0.001)
        #expect(abs((beforeImage.y + delta.height) - afterImage.y) < 0.001)
    }

    @Test("选区没变时平移量为零")
    func regionResizeImageDeltaZero() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 80)
        let delta = SelectionGeometry.imageDelta(from: rect, to: rect, scale: 2)
        #expect(delta == .zero)
    }
}
