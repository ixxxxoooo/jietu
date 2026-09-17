import CoreGraphics
import Testing
@testable import Jietu

@Suite("钉图几何与缩放")
struct PinGeometryTests {

    // MARK: - Handle Hit Testing

    @Test("边缘与角落调整手柄命中检测")
    func handleHitTesting() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)

        // 4 个角落（判定阈值 12pt）
        #expect(PinGeometry.handle(at: CGPoint(x: 5, y: 195), in: bounds) == .topLeft)
        #expect(PinGeometry.handle(at: CGPoint(x: 195, y: 195), in: bounds) == .topRight)
        #expect(PinGeometry.handle(at: CGPoint(x: 5, y: 5), in: bounds) == .bottomLeft)
        #expect(PinGeometry.handle(at: CGPoint(x: 195, y: 5), in: bounds) == .bottomRight)

        // 4 条边缘（判定阈值 8pt，且避开角落）
        #expect(PinGeometry.handle(at: CGPoint(x: 100, y: 195), in: bounds) == .top)
        #expect(PinGeometry.handle(at: CGPoint(x: 100, y: 5), in: bounds) == .bottom)
        #expect(PinGeometry.handle(at: CGPoint(x: 5, y: 100), in: bounds) == .left)
        #expect(PinGeometry.handle(at: CGPoint(x: 195, y: 100), in: bounds) == .right)

        // 视图内部
        #expect(PinGeometry.handle(at: CGPoint(x: 50, y: 50), in: bounds) == nil)
        #expect(PinGeometry.handle(at: CGPoint(x: 100, y: 100), in: bounds) == nil)

        // 超出边界
        #expect(PinGeometry.handle(at: CGPoint(x: -5, y: 100), in: bounds) == nil)
        #expect(PinGeometry.handle(at: CGPoint(x: 205, y: 100), in: bounds) == nil)

        // 过小的视图（小于两倍角落判定区）不触发手柄
        let tinyBounds = CGRect(x: 0, y: 0, width: 20, height: 20)
        #expect(PinGeometry.handle(at: CGPoint(x: 5, y: 5), in: tinyBounds) == nil)
    }

    // MARK: - Resized Frame (Corners)

    @Test("右上角拖拽：固定左下角并保持宽高比")
    func topRightResizeAnchorsBottomLeftAndPreservesRatio() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        let ratio: CGFloat = 2.0
        let startMouse = CGPoint(x: 300, y: 200)
        let currentMouse = CGPoint(x: 340, y: 220) // +40, +20

        let resized = PinGeometry.resizedFrame(
            startFrame: start,
            handle: .topRight,
            startMouse: startMouse,
            currentMouse: currentMouse,
            aspectRatio: ratio
        )

        // 左下角作为不动锚点
        #expect(resized.minX == start.minX)
        #expect(resized.minY == start.minY)

        // 比例严格保持 2.0
        #expect(abs(resized.width / resized.height - ratio) < 0.0001)
        #expect(abs(resized.width - 240) < 0.0001)
        #expect(abs(resized.height - 120) < 0.0001)
    }

    @Test("右下角拖拽：固定左上角并保持宽高比")
    func bottomRightResizeAnchorsTopLeftAndPreservesRatio() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        let ratio: CGFloat = 2.0
        let startMouse = CGPoint(x: 300, y: 100)
        let currentMouse = CGPoint(x: 340, y: 80) // dx=+40, dy=-20 (向下扩 20)

        let resized = PinGeometry.resizedFrame(
            startFrame: start,
            handle: .bottomRight,
            startMouse: startMouse,
            currentMouse: currentMouse,
            aspectRatio: ratio
        )

        // 左上角作为不动锚点
        #expect(resized.minX == start.minX)
        #expect(resized.maxY == start.maxY)

        #expect(abs(resized.width / resized.height - ratio) < 0.0001)
        #expect(abs(resized.width - 240) < 0.0001)
        #expect(abs(resized.height - 120) < 0.0001)
        #expect(abs(resized.minY - (start.maxY - 120)) < 0.0001)
    }

    @Test("左上角拖拽：固定右下角并保持宽高比")
    func topLeftResizeAnchorsBottomRightAndPreservesRatio() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        let ratio: CGFloat = 2.0
        let startMouse = CGPoint(x: 100, y: 200)
        let currentMouse = CGPoint(x: 60, y: 220) // dx=-40 (向左扩 40), dy=+20 (向上扩 20)

        let resized = PinGeometry.resizedFrame(
            startFrame: start,
            handle: .topLeft,
            startMouse: startMouse,
            currentMouse: currentMouse,
            aspectRatio: ratio
        )

        // 右下角作为不动锚点
        #expect(resized.maxX == start.maxX)
        #expect(resized.minY == start.minY)

        #expect(abs(resized.width / resized.height - ratio) < 0.0001)
        #expect(abs(resized.width - 240) < 0.0001)
        #expect(abs(resized.height - 120) < 0.0001)
        #expect(abs(resized.minX - (start.maxX - 240)) < 0.0001)
    }

    @Test("左下角拖拽：固定右上角并保持宽高比")
    func bottomLeftResizeAnchorsTopRightAndPreservesRatio() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        let ratio: CGFloat = 2.0
        let startMouse = CGPoint(x: 100, y: 100)
        let currentMouse = CGPoint(x: 60, y: 80) // dx=-40, dy=-20

        let resized = PinGeometry.resizedFrame(
            startFrame: start,
            handle: .bottomLeft,
            startMouse: startMouse,
            currentMouse: currentMouse,
            aspectRatio: ratio
        )

        // 右上角作为不动锚点
        #expect(resized.maxX == start.maxX)
        #expect(resized.maxY == start.maxY)

        #expect(abs(resized.width / resized.height - ratio) < 0.0001)
        #expect(abs(resized.width - 240) < 0.0001)
        #expect(abs(resized.height - 120) < 0.0001)
        #expect(abs(resized.minX - (start.maxX - 240)) < 0.0001)
        #expect(abs(resized.minY - (start.maxY - 120)) < 0.0001)
    }

    // MARK: - Resized Frame (Edges)

    @Test("右边缘拖拽：固定左边且垂直居中扩展")
    func rightResizeAnchorsLeftEdgeAndCentersY() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        let ratio: CGFloat = 2.0
        let startMouse = CGPoint(x: 300, y: 150)
        let currentMouse = CGPoint(x: 340, y: 150) // dx = +40

        let resized = PinGeometry.resizedFrame(
            startFrame: start,
            handle: .right,
            startMouse: startMouse,
            currentMouse: currentMouse,
            aspectRatio: ratio
        )

        // 左边保持固定
        #expect(resized.minX == start.minX)
        #expect(abs(resized.width - 240) < 0.0001)
        #expect(abs(resized.height - 120) < 0.0001)
        // Y 轴中心对称扩展
        #expect(abs(resized.midY - start.midY) < 0.0001)
        #expect(abs(resized.width / resized.height - ratio) < 0.0001)
    }

    @Test("上边缘拖拽：固定底边且水平居中扩展")
    func topResizeAnchorsBottomEdgeAndCentersX() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        let ratio: CGFloat = 2.0
        let startMouse = CGPoint(x: 200, y: 200)
        let currentMouse = CGPoint(x: 200, y: 220) // dy = +20

        let resized = PinGeometry.resizedFrame(
            startFrame: start,
            handle: .top,
            startMouse: startMouse,
            currentMouse: currentMouse,
            aspectRatio: ratio
        )

        // 底边保持固定
        #expect(resized.minY == start.minY)
        #expect(abs(resized.height - 120) < 0.0001)
        #expect(abs(resized.width - 240) < 0.0001)
        // X 轴中心对称扩展
        #expect(abs(resized.midX - start.midX) < 0.0001)
        #expect(abs(resized.width / resized.height - ratio) < 0.0001)
    }

    @Test("边缘调整限制最小边长")
    func resizeEnforcesMinimumSide() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        let ratio: CGFloat = 2.0
        let startMouse = CGPoint(x: 300, y: 200)
        let currentMouse = CGPoint(x: 0, y: 0) // 大幅向内拖拽

        let resized = PinGeometry.resizedFrame(
            startFrame: start,
            handle: .topRight,
            startMouse: startMouse,
            currentMouse: currentMouse,
            aspectRatio: ratio,
            minSide: 60
        )

        #expect(resized.width >= 60)
        #expect(resized.height >= 30)
        #expect(abs(resized.width / resized.height - ratio) < 0.0001)
    }

    // MARK: - Zoom (Focused Zoom)

    @Test("滚轮/捏合缩放：鼠标焦点在屏幕上的物理坐标严格不变")
    func zoomPreservesMouseFocusPoint() {
        let start = CGRect(x: 200, y: 300, width: 400, height: 200)
        let ratio: CGFloat = 2.0
        // 假设鼠标位于窗口内部任意位置 (100, 50) -> 归一化比例 (0.25, 0.25)
        let mouseInWindow = CGPoint(x: 100, y: 50)
        let mouseScreenBefore = CGPoint(
            x: start.minX + mouseInWindow.x,
            y: start.minY + mouseInWindow.y
        ) // (300, 350)

        // 放大 1.5 倍
        let zoomed = PinGeometry.zoomedFrame(
            currentFrame: start,
            factor: 1.5,
            mouseLocationInWindow: mouseInWindow,
            aspectRatio: ratio
        )

        // 1. 宽高按 1.5 倍扩大且保持比例
        #expect(abs(zoomed.width - 600) < 0.0001)
        #expect(abs(zoomed.height - 300) < 0.0001)
        #expect(abs(zoomed.width / zoomed.height - ratio) < 0.0001)

        // 2. 缩放后，鼠标焦点处的屏幕物理坐标严格保持不变！
        let unitX: CGFloat = 100 / 400
        let unitY: CGFloat = 50 / 200
        let mouseScreenAfter = CGPoint(
            x: zoomed.minX + unitX * zoomed.width,
            y: zoomed.minY + unitY * zoomed.height
        )

        #expect(abs(mouseScreenAfter.x - mouseScreenBefore.x) < 0.0001)
        #expect(abs(mouseScreenAfter.y - mouseScreenBefore.y) < 0.0001)
    }

    @Test("鼠标位于中心时向四周对称扩展")
    func zoomAtCenterExpandsEqually() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        let ratio: CGFloat = 2.0
        let mouseInWindow = CGPoint(x: 100, y: 50) // 正中心

        let zoomed = PinGeometry.zoomedFrame(
            currentFrame: start,
            factor: 2.0,
            mouseLocationInWindow: mouseInWindow,
            aspectRatio: ratio
        )

        #expect(abs(zoomed.width - 400) < 0.0001)
        #expect(abs(zoomed.height - 200) < 0.0001)
        #expect(abs(zoomed.midX - start.midX) < 0.0001)
        #expect(abs(zoomed.midY - start.midY) < 0.0001)
    }

    // MARK: - 卡片外框（contentInset）

    @Test("带外框拖动：锁的是截图的比例，外框两边各留一圈")
    func resizeWithCardInsetKeepsContentRatio() {
        let inset: CGFloat = 8
        // 窗口 216×116 = 截图 200×100 + 外框一圈。
        let start = CGRect(x: 100, y: 100, width: 216, height: 116)
        let ratio: CGFloat = 2.0
        let resized = PinGeometry.resizedFrame(
            startFrame: start,
            handle: .topRight,
            startMouse: CGPoint(x: 316, y: 216),
            currentMouse: CGPoint(x: 356, y: 216), // +40
            aspectRatio: ratio,
            contentInset: inset
        )

        let content = PinGeometry.contentRect(of: resized, inset: inset)
        #expect(abs(content.width / content.height - ratio) < 0.0001, "截图仍严格保持比例")
        #expect(abs(content.width - 240) < 0.0001)
        #expect(abs(content.height - 120) < 0.0001)
        #expect(abs(resized.width - 256) < 0.0001, "窗口 = 截图 + 两边外框")
        #expect(abs(resized.height - 136) < 0.0001)
        // 锚点（左下角）不动
        #expect(resized.minX == start.minX)
        #expect(resized.minY == start.minY)
    }

    @Test("带外框缩放：鼠标焦点下的像素在屏幕上不动")
    func zoomWithCardInsetPreservesMouseFocusPoint() {
        let inset: CGFloat = 8
        let start = CGRect(x: 200, y: 300, width: 416, height: 216) // 截图 400×200
        let ratio: CGFloat = 2.0
        let mouseInWindow = CGPoint(x: 108, y: 58) // 换成截图坐标是 (100, 50)
        let contentBefore = PinGeometry.contentRect(of: start, inset: inset)
        let unitX = (mouseInWindow.x - inset) / contentBefore.width
        let unitY = (mouseInWindow.y - inset) / contentBefore.height
        let screenBefore = CGPoint(
            x: contentBefore.minX + unitX * contentBefore.width,
            y: contentBefore.minY + unitY * contentBefore.height
        )

        let zoomed = PinGeometry.zoomedFrame(
            currentFrame: start,
            factor: 1.5,
            mouseLocationInWindow: mouseInWindow,
            aspectRatio: ratio,
            contentInset: inset
        )

        let contentAfter = PinGeometry.contentRect(of: zoomed, inset: inset)
        #expect(abs(contentAfter.width - 600) < 0.0001)
        #expect(abs(contentAfter.height - 300) < 0.0001)
        #expect(abs(contentAfter.width / contentAfter.height - ratio) < 0.0001)
        let screenAfter = CGPoint(
            x: contentAfter.minX + unitX * contentAfter.width,
            y: contentAfter.minY + unitY * contentAfter.height
        )
        #expect(abs(screenAfter.x - screenBefore.x) < 0.0001)
        #expect(abs(screenAfter.y - screenBefore.y) < 0.0001)
    }

    @Test("缩放系数 1.0 尺寸与原点保持不变")
    func zoomFactorOneLeavesFrameUnchanged() {
        let start = CGRect(x: 150, y: 250, width: 300, height: 150)
        let ratio: CGFloat = 2.0
        let mouseInWindow = CGPoint(x: 80, y: 40)

        let zoomed = PinGeometry.zoomedFrame(
            currentFrame: start,
            factor: 1.0,
            mouseLocationInWindow: mouseInWindow,
            aspectRatio: ratio
        )

        #expect(abs(zoomed.origin.x - start.origin.x) < 0.0001)
        #expect(abs(zoomed.origin.y - start.origin.y) < 0.0001)
        #expect(abs(zoomed.size.width - start.size.width) < 0.0001)
        #expect(abs(zoomed.size.height - start.size.height) < 0.0001)
    }
}
