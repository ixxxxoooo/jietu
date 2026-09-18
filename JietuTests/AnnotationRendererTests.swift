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

    @Test("荧光笔是半透明笔迹：笔迹正中是混出的中间色，笔迹外是底色")
    func highlightIsTranslucentStroke() throws {
        let base = TestImage.solidBlack(side: 40)
        let annotation = Annotation(
            kind: .highlight(points: [CGPoint(x: 5, y: 20), CGPoint(x: 35, y: 20)]),
            color: .yellow,
            lineWidth: 2
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))
        // 黑色底 + 黄色半透明 → 偏黄的中间色，而不是纯黄。
        let onStroke = try sample(rendered, 20, 20)
        #expect(onStroke.red > 60)
        #expect(onStroke.green > 60)
        #expect(onStroke.blue < 80)
        // 笔迹之外仍是原底色。
        let offStroke = try sample(rendered, 20, 2)
        #expect(offStroke.red <= 40)
    }

    @Test("荧光笔画出来的是「笔尖粗细 × 6」的粗笔迹")
    func highlightBrushIsWide() throws {
        let brush = Annotation(
            kind: .highlight(points: [CGPoint(x: 5, y: 20), CGPoint(x: 75, y: 20)]),
            color: .yellow,
            lineWidth: 3
        )
        #expect(brush.highlightBrushWidth == 18)
        let base = TestImage.solidBlack(side: 40)
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [brush]))
        // 笔宽 18 → 中心上下各 8px 在笔迹里，12px 已经在外面。
        #expect(try sample(rendered, 39, 12).red > 60)
        #expect(try sample(rendered, 39, 28).red > 60)
        #expect(try sample(rendered, 39, 6).red <= 40)
    }

    @Test("荧光笔来回涂同一处不会越涂越深（整条笔迹一层半透明）")
    func highlightDoesNotCompoundAlpha() throws {
        let base = TestImage.solidBlack(side: 40)
        func marker(_ points: [CGPoint]) -> Annotation {
            Annotation(kind: .highlight(points: points), color: .yellow, lineWidth: 2)
        }
        let straight = try #require(
            AnnotationRenderer.render(base: base, annotations: [marker([CGPoint(x: 5, y: 20), CGPoint(x: 35, y: 20)])])
        )
        let backAndForth = try #require(
            AnnotationRenderer.render(
                base: base,
                annotations: [marker([CGPoint(x: 5, y: 20), CGPoint(x: 35, y: 20), CGPoint(x: 5, y: 20)])]
            )
        )
        let once = try sample(straight, 20, 20)
        let twice = try sample(backAndForth, 20, 20)
        #expect(abs(Int(once.red) - Int(twice.red)) <= 2)
        #expect(abs(Int(once.green) - Int(twice.green)) <= 2)
    }

    @Test("聚光灯：窗口内原样透出，窗口外整幅压暗")
    func spotlightDimsOutsideWindow() throws {
        let base = TestImage.make(width: 40, height: 40) { _, _ in (255, 255, 255) }
        let annotation = Annotation(
            kind: .spotlight(CGRect(x: 10, y: 10, width: 20, height: 20)),
            color: .black,
            lineWidth: 3
        )
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [annotation]))
        let inside = try sample(rendered, 20, 20)
        #expect(inside.red >= 250)
        // 255 × (1 − 0.52) ≈ 122。
        let outside = try sample(rendered, 2, 2)
        #expect(outside.red >= 100 && outside.red <= 145)
    }

    @Test("聚光灯：多个窗口合成一层，重叠处不会被压两次")
    func multipleSpotlightsShareOneLayer() throws {
        let base = TestImage.make(width: 60, height: 40) { _, _ in (255, 255, 255) }
        let left = Annotation(kind: .spotlight(CGRect(x: 0, y: 0, width: 40, height: 40)), color: .black)
        let right = Annotation(kind: .spotlight(CGRect(x: 20, y: 0, width: 40, height: 40)), color: .black)
        let rendered = try #require(AnnotationRenderer.render(base: base, annotations: [left, right]))
        #expect(try sample(rendered, 10, 20).red >= 250)
        #expect(try sample(rendered, 30, 20).red >= 250)
        #expect(try sample(rendered, 50, 20).red >= 250)
    }

    @Test("聚光灯压在标注之上：框外的标注也一起变暗")
    func spotlightDimsAnnotationsToo() throws {
        let base = TestImage.solidBlack(side: 40)
        let line = Annotation(
            kind: .line(from: CGPoint(x: 2, y: 6), to: CGPoint(x: 38, y: 6)),
            color: .white,
            lineWidth: 4
        )
        let window = Annotation(
            kind: .spotlight(CGRect(x: 10, y: 20, width: 20, height: 16)),
            color: .black,
            lineWidth: 3
        )
        let rendered = try #require(
            AnnotationRenderer.render(base: base, annotations: [line, window])
        )
        // 白线（255）在聚光灯外 → 被压暗到 255 × 0.48 ≈ 122。
        let dimmed = try sample(rendered, 20, 6)
        #expect(dimmed.red >= 100 && dimmed.red <= 145)
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
