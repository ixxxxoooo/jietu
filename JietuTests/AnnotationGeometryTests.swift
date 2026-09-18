import CoreGraphics
import Testing
@testable import Jietu

/// 标注对象的几何与编辑行为。
///
/// @author ixxxxoooo
@Suite("标注几何")
struct AnnotationGeometryTests {
    private func rectAnnotation() -> Annotation {
        Annotation(
            kind: .rectangle(CGRect(x: 100, y: 100, width: 200, height: 100)),
            color: .red,
            lineWidth: 4
        )
    }

    @Test("包围盒与中心")
    func boundsAndCenter() {
        let annotation = rectAnnotation()
        #expect(annotation.localBounds == CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(annotation.center == CGPoint(x: 200, y: 150))
    }

    @Test("矩形只认边框：边上命中，框中间留白（能继续画别的），外面不命中")
    func hitTesting() {
        let annotation = rectAnnotation()  // (100,100,200x100)，线宽 4
        // 四条边上都命中。
        #expect(annotation.contains(CGPoint(x: 100, y: 150)))
        #expect(annotation.contains(CGPoint(x: 300, y: 150)))
        #expect(annotation.contains(CGPoint(x: 200, y: 100)))
        #expect(annotation.contains(CGPoint(x: 200, y: 200)))
        // 框**中间**是留白：不算命中，否则在里面再画一个框画不上（用户报过）。
        #expect(!annotation.contains(CGPoint(x: 200, y: 150)))
        // 离了边框足够远的地方也不命中。
        #expect(!annotation.contains(CGPoint(x: 20, y: 20)))
        #expect(!annotation.contains(CGPoint(x: 200, y: 150 + 30)))
    }

    @Test("椭圆也只认那一圈线")
    func ellipseHitTesting() {
        let annotation = Annotation(
            kind: .ellipse(CGRect(x: 100, y: 100, width: 200, height: 100)),
            color: .red,
            lineWidth: 4
        )
        // 左右顶点 / 上下顶点在线上。
        #expect(annotation.contains(CGPoint(x: 100, y: 150)))
        #expect(annotation.contains(CGPoint(x: 300, y: 150)))
        #expect(annotation.contains(CGPoint(x: 200, y: 100)))
        #expect(annotation.contains(CGPoint(x: 200, y: 200)))
        // 圆心、以及「矩形四角」这种椭圆外面的位置都不命中。
        #expect(!annotation.contains(CGPoint(x: 200, y: 150)))
        #expect(!annotation.contains(CGPoint(x: 105, y: 105)))
    }

    @Test("实心标注仍然整块命中：高亮 / 模糊 / 马赛克")
    func filledShapesHitWholeArea() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let center = CGPoint(x: 200, y: 150)
        #expect(Annotation(kind: .highlight(rect), color: .red, lineWidth: 4).contains(center))
        #expect(Annotation(kind: .blur(rect, radius: 12), color: .red, lineWidth: 4).contains(center))
        #expect(Annotation(kind: .pixelate(rect, block: 12), color: .red, lineWidth: 4).contains(center))
    }

    @Test("平移后包围盒整体移动")
    func translate() {
        let moved = rectAnnotation().translated(by: CGSize(width: 30, height: -20))
        #expect(moved.localBounds == CGRect(x: 130, y: 80, width: 200, height: 100))
    }

    @Test("拖右下角控制点改变矩形大小")
    func resize() {
        let resized = rectAnnotation().resized(
            handle: .bottomRight,
            to: CGPoint(x: 400, y: 300),
            lockAspect: false
        )
        #expect(resized.localBounds == CGRect(x: 100, y: 100, width: 300, height: 200))
    }

    @Test("旋转后角点绕中心转动")
    func rotate() {
        let rotated = rectAnnotation().rotated(by: .pi / 2)
        let corners = rotated.rotatedCorners()
        // 中心不变
        #expect(Annotation.distance(rotated.center, CGPoint(x: 200, y: 150)) < 0.001)
        // 旋转 90° 后，四个角点整体转动到预期位置
        let expected = [
            CGPoint(x: 150, y: 50),
            CGPoint(x: 250, y: 50),
            CGPoint(x: 250, y: 250),
            CGPoint(x: 150, y: 250),
        ]
        for corner in expected {
            #expect(corners.contains { Annotation.distance($0, corner) < 0.5 })
        }
    }

    @Test("箭头端点可拖动")
    func arrowEndpoint() {
        let arrow = Annotation(
            kind: .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), control: nil),
            color: .red
        )
        let moved = arrow.withEndpoint(.arrowEnd, to: CGPoint(x: 50, y: 80))
        guard case .arrow(_, let to, _) = moved.kind else {
            Issue.record("kind 不再是 arrow")
            return
        }
        #expect(to == CGPoint(x: 50, y: 80))
    }

    @Test("画箭头控制点后变成曲线")
    func arrowCurve() {
        let arrow = Annotation(
            kind: .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), control: nil),
            color: .red
        )
        let curved = arrow.withEndpoint(.arrowControl, to: CGPoint(x: 50, y: 40))
        guard case .arrow(_, _, let control) = curved.kind else {
            Issue.record("kind 不再是 arrow")
            return
        }
        #expect(control == CGPoint(x: 50, y: 40))
    }

    @Test("文字尺寸测量非零")
    func textSize() {
        let size = Annotation.textSize(string: "Hello", fontSize: 20)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test("序号可带引线")
    func counterLeader() {
        let counter = Annotation(
            kind: .counter(center: CGPoint(x: 50, y: 50), value: 3, leader: nil),
            color: .red
        )
        let withLeader = counter.withEndpoint(.counterLeader, to: CGPoint(x: 90, y: 90))
        guard case .counter(_, let value, let leader) = withLeader.kind else {
            Issue.record("kind 不再是 counter")
            return
        }
        #expect(value == 3)
        #expect(leader == CGPoint(x: 90, y: 90))
    }

    @Test("复制样式：颜色与线宽搬运到另一条标注")
    func copiesStyleBetweenAnnotations() {
        let source = Annotation(
            kind: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)),
            color: .blue,
            lineWidth: 9
        )
        let style = AnnotationStyle(from: source)

        let target = Annotation(
            kind: .ellipse(CGRect(x: 50, y: 50, width: 20, height: 20)),
            color: .red,
            lineWidth: 2
        )
        let styled = style.applied(to: target)

        #expect(styled.color == .blue)
        #expect(styled.lineWidth == 9)
        // 几何量不受影响。
        #expect(styled.kind == target.kind)
    }

    @Test("复制样式：字号与马赛克块只在同类标注上生效")
    func appliesStyleOnlyToRelevantKinds() {
        let text = Annotation(
            kind: .text(origin: .zero, string: "hi", fontSize: 42),
            color: .green,
            lineWidth: 5
        )
        let mosaic = Annotation(
            kind: .pixelate(CGRect(x: 0, y: 0, width: 40, height: 40), block: 20),
            color: .black,
            lineWidth: 1
        )

        // 从文字取样式贴到马赛克：字号不该污染马赛克块。
        let style = AnnotationStyle(from: text)
        let styledMosaic = style.applied(to: mosaic)
        guard case .pixelate(_, let block) = styledMosaic.kind else {
            Issue.record("kind 不再是 pixelate")
            return
        }
        #expect(block == 20)
        #expect(styledMosaic.color == .green)

        // 反过来：从马赛克取样式贴到文字，字号保持原值。
        let mosaicStyle = AnnotationStyle(from: mosaic)
        let styledText = mosaicStyle.applied(to: text)
        guard case .text(_, _, let fontSize) = styledText.kind else {
            Issue.record("kind 不再是 text")
            return
        }
        #expect(fontSize == 42)
        #expect(styledText.lineWidth == 1)
    }

    @Test("直线：包围盒、命中与端点拖动")
    func lineGeometry() {
        let line = Annotation(
            kind: .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100)),
            color: .red,
            lineWidth: 3
        )
        #expect(line.localBounds == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(line.contains(CGPoint(x: 50, y: 50)))
        #expect(!line.contains(CGPoint(x: 50, y: 95)))

        let moved = line.withEndpoint(.lineEnd, to: CGPoint(x: 0, y: 100))
        guard case .line(_, let to) = moved.kind else {
            Issue.record("kind 不再是 line")
            return
        }
        #expect(to == CGPoint(x: 0, y: 100))
    }

    @Test("模糊：跟随矩形缩放，参数独立")
    func blurFollowsResize() {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
        let blur = Annotation(kind: .blur(rect, radius: 8), color: .red, lineWidth: 3)
        #expect(blur.localBounds == rect)

        let resized = blur.resized(handle: .bottomRight, to: CGPoint(x: 90, y: 90), lockAspect: false)
        #expect(resized.localBounds == CGRect(x: 10, y: 10, width: 80, height: 80))
        #expect(blur.withBlurRadius(20).kind == .blur(rect, radius: 20))
        #expect(resized.withBlurRadius(20).kind == .blur(CGRect(x: 10, y: 10, width: 80, height: 80), radius: 20))

        // 样式搬运带上各自的参数。
        let style = AnnotationStyle(from: blur)
        #expect(style.blurRadius == 8)
        // 样式搬运只作用在同类标注上：矩形不吃模糊半径。
        let rectangle = Annotation(kind: .rectangle(rect), color: .red, lineWidth: 3)
        let styled = style.applied(to: rectangle)
        #expect(styled.kind == .rectangle(rect))
        #expect(styled.color == .red)
    }

    // MARK: - 截后再裁剪
    @Test("裁剪框被夹进图像范围，过小则判为无效")
    func clampsCropRect() {
        let size = CGSize(width: 100, height: 80)
        #expect(CropOperation.clampedRect(CGRect(x: 20, y: 10, width: 40, height: 30), imageSize: size)
            == CGRect(x: 20, y: 10, width: 40, height: 30))
        // 超出右下角 → 夹到边界。
        #expect(CropOperation.clampedRect(CGRect(x: 80, y: 60, width: 50, height: 50), imageSize: size)
            == CGRect(x: 80, y: 60, width: 20, height: 20))
        // 太小 / 完全在外面。
        #expect(CropOperation.clampedRect(CGRect(x: 0, y: 0, width: 2, height: 2), imageSize: size) == nil)
        #expect(CropOperation.clampedRect(CGRect(x: 200, y: 200, width: 10, height: 10), imageSize: size) == nil)
    }

    @Test("裁剪底图：尺寸与保留的像素区域正确")
    func cropsImage() throws {
        // 顶两行红、其余蓝。
        let image = TestImage.horizontalBands(
            width: 8,
            height: 8,
            rows: [(255, 0, 0), (255, 0, 0), (0, 0, 255)]
        )
        let result = try #require(
            CropOperation.crop(image, to: CGRect(x: 0, y: 0, width: 4, height: 4))
        )
        #expect(result.image.width == 4)
        #expect(result.image.height == 4)

        // 裁的仍是左上角：前两行红、后面蓝。
        let top = try #require(PixelSampler.sample(result.image, atPixel: CGPoint(x: 1, y: 1)))
        #expect(top.red == 255)
        #expect(top.blue == 0)
        let bottom = try #require(PixelSampler.sample(result.image, atPixel: CGPoint(x: 1, y: 3)))
        #expect(bottom.blue == 255)
        #expect(bottom.red == 0)
    }

    @Test("裁剪后标注与擦除笔迹一起平移")
    func shiftsContentAfterCrop() {
        let annotation = rectAnnotation()
        let delta = CropOperation.offset(for: CGRect(x: 30, y: 60, width: 100, height: 100))
        #expect(delta == CGSize(width: -30, height: -60))

        let shifted = CropOperation.shifted([annotation], by: delta)
        #expect(shifted.first?.localBounds == CGRect(x: 70, y: 40, width: 200, height: 100))

        let strokes = [EraserStroke(points: [CGPoint(x: 50, y: 70)], radius: 8)]
        let shiftedStrokes = CropOperation.shifted(strokes, by: delta)
        #expect(shiftedStrokes.first?.points.first == CGPoint(x: 20, y: 10))
        #expect(shiftedStrokes.first?.radius == 8)
    }

    @Test("文字选框具备对称安全内边距且文字在选框内严格居中")
    func textBoundsAreSymmetricallyCentered() {
        let origin = CGPoint(x: 100, y: 100)
        let fontSize: CGFloat = 24
        let string = "对对对"
        let annotation = Annotation(
            kind: .text(origin: origin, string: string, fontSize: fontSize),
            color: .red
        )
        let textSize = Annotation.textSize(string: string, fontSize: fontSize)
        let pad = Annotation.textPadding(fontSize: fontSize)
        let box = annotation.localBounds

        // 验证边距对称性
        #expect(box.minX == origin.x - pad.x)
        #expect(box.maxX == origin.x + textSize.width + pad.x)
        #expect(box.minY == origin.y - pad.y)
        #expect(box.maxY == origin.y + textSize.height + pad.y)

        // 验证文字几何中心与选框几何中心完全一致
        let textCenter = CGPoint(x: origin.x + textSize.width / 2, y: origin.y + textSize.height / 2)
        let boxCenter = CGPoint(x: box.midX, y: box.midY)
        #expect(abs(textCenter.x - boxCenter.x) < 0.001)
        #expect(abs(textCenter.y - boxCenter.y) < 0.001)
        #expect(annotation.center == boxCenter)
    }

    @Test("文字标注缩放后依然保持在选框内对称居中")
    func textResizingMaintainsCentering() {
        let origin = CGPoint(x: 50, y: 50)
        let fontSize: CGFloat = 20
        let string = "居中文本"
        let annotation = Annotation(
            kind: .text(origin: origin, string: string, fontSize: fontSize),
            color: .red
        )
        let resized = annotation.resized(
            handle: .bottomRight,
            to: CGPoint(x: 200, y: 120),
            lockAspect: false
        )
        guard case .text(let newOrigin, _, let newFontSize) = resized.kind else {
            Issue.record("kind 不再是 text")
            return
        }
        let newTextSize = Annotation.textSize(string: string, fontSize: newFontSize)
        let newPad = Annotation.textPadding(fontSize: newFontSize)
        let newBox = resized.localBounds

        #expect(newBox.minX == newOrigin.x - newPad.x)
        #expect(newBox.maxX == newOrigin.x + newTextSize.width + newPad.x)
        #expect(newBox.minY == newOrigin.y - newPad.y)
        #expect(newBox.maxY == newOrigin.y + newTextSize.height + newPad.y)

        let textCenter = CGPoint(x: newOrigin.x + newTextSize.width / 2, y: newOrigin.y + newTextSize.height / 2)
        let boxCenter = CGPoint(x: newBox.midX, y: newBox.midY)
        #expect(abs(textCenter.x - boxCenter.x) < 0.001)
        #expect(abs(textCenter.y - boxCenter.y) < 0.001)
    }
}
