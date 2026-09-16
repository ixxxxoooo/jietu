import CoreGraphics
import Testing
@testable import Jietu

/// 标注渲染的像素级验证。
///
/// @author ixxxxoooo
@Suite("标注渲染")
struct AnnotationRendererTests {
    private func sample(_ image: CGImage, _ x: Int, _ y: Int) throws -> PixelSampler.Sample {
        try #require(PixelSampler.sample(image, atPixel: CGPoint(x: x, y: y)))
    }

    @Test("无标注时输出与原图同尺寸")
    func renderEmptyKeepsSize() throws {
        let base = TestImage.solidBlack(side: 20)
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: []))
        #expect(rendered.width == 20)
        #expect(rendered.height == 20)
    }

    @Test("矩形描边落在边界上，内部保持背景")
    func rectangleStroke() throws {
        let base = TestImage.solidBlack(side: 20)
        let annotation = Annotation(
            kind: .rectangle(CGRect(x: 2, y: 2, width: 16, height: 16)),
            color: .white,
            lineWidth: 2
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))

        let edge = try sample(rendered, 2, 10)
        #expect(edge.red >= 200 && edge.green >= 200 && edge.blue >= 200)

        let center = try sample(rendered, 10, 10)
        #expect(center.red <= 40 && center.green <= 40 && center.blue <= 40)
    }

    @Test("序号圆点填充颜色")
    func counterFillsCircle() throws {
        let base = TestImage.solidBlack(side: 40)
        let annotation = Annotation(
            kind: .counter(center: CGPoint(x: 20, y: 20), value: 1, leader: nil),
            color: .red,
            lineWidth: 3
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))
        let point = try sample(rendered, 20, 29)
        #expect(point.red >= 200 && point.green <= 90 && point.blue <= 90)
    }

    @Test("马赛克把细粒度图案合并成块")
    func pixelateBlocks() throws {
        let checker = TestImage.make(width: 16, height: 16) { x, y in
            (x + y) % 2 == 0 ? (0, 0, 0) : (255, 255, 255)
        }
        let annotation = Annotation(
            kind: .pixelate(CGRect(x: 0, y: 0, width: 16, height: 16), block: 8),
            color: .black
        )
        let rendered = try #require(AnnotationRenderer.render(base: checker, annotations: [annotation]))
        let first = try sample(rendered, 0, 0)
        let second = try sample(rendered, 1, 0)
        #expect(first.red == second.red)
        #expect(first.green == second.green)
        #expect(first.blue == second.blue)
    }

    @Test("高亮是半透明叠加，不会变成纯色")
    func highlightIsTranslucent() throws {
        let base = TestImage.solidBlack(side: 20)
        let annotation = Annotation(
            kind: .highlight(CGRect(x: 0, y: 0, width: 20, height: 20)),
            color: .yellow
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))
        let point = try sample(rendered, 10, 10)
        // 黑色底 + 黄色半透明 → 混出偏黄的中间色，而不是纯黄。
        #expect(point.red > 60)
        #expect(point.green > 60)
        #expect(point.blue < 80)
    }

    @Test("直线按线宽画出实心笔迹")
    func lineStroke() throws {
        let base = TestImage.solidBlack(side: 20)
        let annotation = Annotation(
            kind: .line(from: CGPoint(x: 2, y: 10), to: CGPoint(x: 18, y: 10)),
            color: .white,
            lineWidth: 3
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))
        let onLine = try sample(rendered, 10, 10)
        #expect(onLine.red >= 200)
        let offLine = try sample(rendered, 10, 2)
        #expect(offLine.red <= 40)
    }

    @Test("模糊把硬边界揉成中间色")
    func blurSoftensEdge() throws {
        // 左黑右白的硬边界。
        let base = TestImage.make(width: 32, height: 16) { x, _ in
            x < 16 ? (0, 0, 0) : (255, 255, 255)
        }
        let annotation = Annotation(
            kind: .blur(CGRect(x: 0, y: 0, width: 32, height: 16), radius: 6),
            color: .white
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))
        // 边界附近不再是纯黑或纯白。
        let edge = try sample(rendered, 15, 8)
        #expect(edge.red > 20 && edge.red < 235)
        // 远离边界的地方仍保持原来的黑。
        let farLeft = try sample(rendered, 0, 8)
        #expect(farLeft.red <= 40)
    }

    @Test("放大镜把内容放大显示")
    func magnifierZoomsContent() throws {
        // 只有正中间一个红点，其余全白。
        let base = TestImage.make(width: 32, height: 32) { x, y in
            (x == 16 && y == 16) ? (255, 0, 0) : (255, 255, 255)
        }
        let annotation = Annotation(
            kind: .magnifier(CGRect(x: 0, y: 0, width: 32, height: 32), zoom: 4),
            color: .black,
            lineWidth: 2
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))

        // 原来 (15,15) 是白的；放大 4 倍后它落在红点边缘，被红点染上颜色。
        let near = try sample(rendered, 15, 15)
        #expect(near.red == 255)
        #expect(near.green < 255)
    }
}
