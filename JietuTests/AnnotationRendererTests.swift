import CoreGraphics
import Testing
@testable import Jietu

/// 标注渲染的像素级验证。
///
/// @author ixxxxoooo
@Suite("标注渲染")
struct AnnotationRendererTests {
    private func color(
        _ image: CGImage,
        _ x: Int,
        _ y: Int
    ) throws -> PixelSampler.Sample {
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
            shape: .rectangle(CGRect(x: 2, y: 2, width: 16, height: 16)),
            color: .white,
            lineWidth: 2
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))

        let edge = try color(rendered, 2, 10)
        #expect(edge.red >= 200 && edge.green >= 200 && edge.blue >= 200)

        let center = try color(rendered, 10, 10)
        #expect(center.red <= 40 && center.green <= 40 && center.blue <= 40)
    }

    @Test("序号圆点填充颜色")
    func counterFillsCircle() throws {
        let base = TestImage.solidBlack(side: 40)
        let annotation = Annotation(
            shape: .counter(center: CGPoint(x: 20, y: 20), value: 1),
            color: .red,
            lineWidth: 3
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))
        // 采样点避开中央白色数字，取圆内靠下的位置。
        let center = try color(rendered, 20, 29)
        #expect(center.red >= 200 && center.green <= 90 && center.blue <= 90)
    }

    @Test("马赛克把细粒度图案合并成块")
    func pixelateBlocks() throws {
        let checker = TestImage.make(width: 16, height: 16) { x, y in
            (x + y) % 2 == 0 ? (0, 0, 0) : (255, 255, 255)
        }
        let annotation = Annotation(
            shape: .pixelate(CGRect(x: 0, y: 0, width: 16, height: 16)),
            color: .black
        )
        let rendered = try #require(AnnotationRenderer.render(base: checker, annotations: [annotation]))

        let first = try color(rendered, 0, 0)
        let second = try color(rendered, 1, 0)
        #expect(first.red == second.red)
        #expect(first.green == second.green)
        #expect(first.blue == second.blue)
    }

    @Test("马赛克只作用于指定区域，区域外不变")
    func pixelateIsScoped() throws {
        let checker = TestImage.make(width: 16, height: 16) { x, y in
            (x + y) % 2 == 0 ? (0, 0, 0) : (255, 255, 255)
        }
        let annotation = Annotation(
            shape: .pixelate(CGRect(x: 0, y: 0, width: 8, height: 8)),
            color: .black
        )
        let rendered = try #require(AnnotationRenderer.render(base: checker, annotations: [annotation]))

        let outsideA = try color(rendered, 12, 12)
        let outsideB = try color(rendered, 13, 12)
        #expect(outsideA.red != outsideB.red)
    }
}
