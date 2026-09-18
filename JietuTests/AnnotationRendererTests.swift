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

    @Test("局部模糊准确作用于指定子区域且不影响区域外")
    func blurPartialRectAtOffset() throws {
        let base = TestImage.make(width: 100, height: 100) { x, _ in
            (x >= 49 && x <= 50) ? (255, 255, 255) : (0, 0, 0)
        }
        let annotation = Annotation(
            kind: .blur(CGRect(x: 30, y: 30, width: 40, height: 40), radius: 6),
            color: .white
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))

        let insideBlurred = try sample(rendered, 45, 50)
        #expect(insideBlurred.red > 20)

        let outsideBelow = try sample(rendered, 45, 85)
        #expect(outsideBelow.red == 0)

        let outsideAbove = try sample(rendered, 45, 15)
        #expect(outsideAbove.red == 0)
    }

    @Test("中文字符绘制不向上溢出 topLeft 且落在正确范围内")
    func chineseTextRendersWithinBounds() throws {
        let base = TestImage.solidBlack(side: 100)
        let origin = CGPoint(x: 20, y: 30)
        let annotation = Annotation(
            kind: .text(origin: origin, string: "对对对", fontSize: 24),
            color: .white
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))

        // topLeft.y 上方不应有白色文字像素（过去因基线算错会导致字形向上溢出至 y=17）
        let abovePoint = try sample(rendered, 30, 25)
        #expect(abovePoint.red == 0)

        // 在文字区域内部应有白色笔画
        var foundWhite = false
        for y in 30...55 {
            for x in 20...80 {
                let pixel = try sample(rendered, x, y)
                if pixel.red > 100 {
                    foundWhite = true
                    break
                }
            }
            if foundWhite { break }
        }
        #expect(foundWhite)
    }

    @Test("橡皮擦除恢复底图背景而不是留空")
    func eraserRestoresBaseImage() throws {
        let base = TestImage.solidBlack(side: 60)
        let rect = Annotation(
            kind: .rectangle(CGRect(x: 10, y: 10, width: 40, height: 40)),
            color: .red,
            lineWidth: 6
        )
        let eraser = Annotation(
            kind: .eraser(points: [CGPoint(x: 10, y: 30), CGPoint(x: 50, y: 30)], radius: 10),
            color: .white
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [rect, eraser]))

        // 擦除中心应恢复为黑色底图
        let erasedPoint = try sample(rendered, 10, 30)
        #expect(erasedPoint.red <= 40)

        // 橡皮未触及的顶部边框依然保留红色
        let nonErasedPoint = try sample(rendered, 30, 10)
        #expect(nonErasedPoint.red >= 200)
    }

    @Test("在擦除区域上绘制的新标注不会被再次擦除")
    func subsequentAnnotationDrawnOnErasedAreaWorks() throws {
        let base = TestImage.solidBlack(side: 60)
        // 1. 先画红色矩形
        let rect = Annotation(
            kind: .rectangle(CGRect(x: 10, y: 10, width: 40, height: 40)),
            color: .red,
            lineWidth: 6
        )
        // 2. 橡皮擦除横跨中间
        let eraser = Annotation(
            kind: .eraser(points: [CGPoint(x: 10, y: 30), CGPoint(x: 50, y: 30)], radius: 10),
            color: .white
        )
        // 3. 在擦除后的位置画一条白色横线
        let line = Annotation(
            kind: .line(from: CGPoint(x: 5, y: 30), to: CGPoint(x: 55, y: 30)),
            color: .white,
            lineWidth: 4
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [rect, eraser, line]))

        // 之前被擦除的位置现在有了新画的白色线段，且正确显示为白色
        let newPoint = try sample(rendered, 30, 30)
        #expect(newPoint.red >= 200 && newPoint.green >= 200 && newPoint.blue >= 200)
    }

    @Test("矩形纯色填充与半透明填充渲染正确")
    func shapeFillModesRender() throws {
        let base = TestImage.solidBlack(side: 40)
        let solidRect = Annotation(
            kind: .rectangle(CGRect(x: 5, y: 5, width: 30, height: 30)),
            color: .red,
            lineWidth: 2,
            shapeFillMode: .opaque
        )
        let solidRendered = try #require(AnnotationRenderer.render(base: base, annotations: [solidRect]))
        let solidCenter = try sample(solidRendered, 20, 20)
        #expect(solidCenter.red >= 200, "纯色填充中心应充满红色")

        let transRect = Annotation(
            kind: .rectangle(CGRect(x: 5, y: 5, width: 30, height: 30)),
            color: .red,
            lineWidth: 2,
            shapeFillMode: .translucent
        )
        let transRendered = try #require(AnnotationRenderer.render(base: base, annotations: [transRect]))
        let transCenter = try sample(transRendered, 20, 20)
        #expect(transCenter.red > 30 && transCenter.red < 200, "半透明填充中心应有适中 alpha 叠色")
    }

    @Test("4 种箭头样式均可正常渲染且不崩溃")
    func arrowStylesRender() throws {
        let base = TestImage.solidBlack(side: 60)
        for style in ArrowStyle.allCases {
            let arrow = Annotation(
                kind: .arrow(from: CGPoint(x: 10, y: 30), to: CGPoint(x: 50, y: 30), control: nil),
                color: .white,
                lineWidth: 3,
                arrowStyle: style
            )
            let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [arrow]))
            let hit = try sample(rendered, 30, 30)
            #expect(hit.red >= 180, "\(style.title) 箭身处应有实心笔迹")
        }
    }

    @Test("文字描边与标注气泡均可正常渲染")
    func textEffectsRender() throws {
        let base = TestImage.solidBlack(side: 60)
        let strokedText = Annotation(
            kind: .text(origin: CGPoint(x: 10, y: 20), string: "Hi", fontSize: 18),
            color: .red,
            lineWidth: 2,
            textHasStroke: true
        )
        let rendered1 = try #require(AnnotationRenderer.render(base: base, annotations: [strokedText]))
        #expect(rendered1.width == 60)

        let calloutText = Annotation(
            kind: .text(origin: CGPoint(x: 10, y: 20), string: "Hi", fontSize: 18),
            color: .red,
            lineWidth: 2,
            textHasCallout: true
        )
        let rendered2 = try #require(AnnotationRenderer.render(base: base, annotations: [calloutText]))
        #expect(rendered2.width == 60)
    }
}
