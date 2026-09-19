import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// 把一组标注烘焙进底图，得到可导出的新位图。
///
/// 只依赖 CoreGraphics/CoreText，便于脱离 UI 做像素级单测。
/// 输入输出的几何量都按**图像像素坐标、原点左上**处理；内部绘制时统一翻到
/// `CGContext` 的原点左下坐标系。旋转绕标注自身中心。
///
/// @author ixxxxoooo
enum AnnotationRenderer {
    /// 马赛克的默认块尺寸（像素）。
    static let mosaicBlock: CGFloat = 8

    /// 渲染底图 + 标注（可再叠加橡皮擦除笔迹）。
    ///
    /// `drawsBase = false` 时输出一张**透明底**的标注层（只有标注本身，马赛克 / 模糊 /
    /// 橡皮依然从 `base` 取像素）：原地预览把它叠在冻结图上，就不必每帧把整张底图
    /// 重画一遍，于是能按**原始分辨率**渲染——线、箭头才是 1:1 的，不再有缩放锯齿。
    static func render(
        base: CGImage,
        annotations: [Annotation],
        eraserStrokes: [EraserStroke] = [],
        drawsBase: Bool = true
    ) -> CGImage? {
        let width = base.width
        let height = base.height
        guard width > 0, height > 0 else { return nil }
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.interpolationQuality = .high
        if drawsBase {
            context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var mosaicCache: [Int: CGImage] = [:]
        var spotlights: [CGRect] = []
        for annotation in annotations {
            // 聚光灯是**整幅**效果（压暗的是框外的一切，包括别的标注），
            // 所以先跳过，等所有标注画完再统一合一层。
            if case .spotlight(let rect) = annotation.kind {
                spotlights.append(rect)
                continue
            }
            draw(
                annotation,
                base: base,
                mosaic: { block in
                    let key = max(1, Int(block.rounded()))
                    if let cached = mosaicCache[key] { return cached }
                    let image = downsample(base, factor: key)
                    mosaicCache[key] = image
                    return image
                },
                in: context,
                imageHeight: height
            )
        }
        if !eraserStrokes.isEmpty {
            for stroke in eraserStrokes {
                drawEraser(stroke.points, radius: stroke.radius, base: base, in: context, imageHeight: height)
            }
        }
        if !spotlights.isEmpty {
            drawSpotlight(spotlights, in: context, imageHeight: height)
        }

        return context.makeImage()
    }

    /// 生成马赛克底图（整图缩小 `factor` 倍）。
    static func downsample(_ image: CGImage, factor: Int) -> CGImage? {
        let divisor = max(1, factor)
        let width = max(1, image.width / divisor)
        let height = max(1, image.height / divisor)
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Drawing

    private static func draw(
        _ annotation: Annotation,
        base: CGImage,
        mosaic: @escaping (CGFloat) -> CGImage?,
        in context: CGContext,
        imageHeight: Int
    ) {
        let color = annotation.color.cgColor
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let body: () -> Void = {
            switch annotation.kind {
            case .rectangle(let rect):
                let cRect = contextRect(rect, imageHeight: imageHeight)
                // 方角 / 圆角：圆角按短边比例倒角（见 `RectCornerStyle.radius(for:style:)`）。
                let path = Self.rectanglePath(cRect, style: annotation.rectCornerStyle)
                switch annotation.shapeFillMode {
                case .none:
                    context.addPath(path)
                    context.strokePath()
                case .opaque:
                    context.addPath(path)
                    context.fillPath()
                case .translucent:
                    context.saveGState()
                    context.setFillColor(annotation.color.cgColor.copy(alpha: 0.28) ?? color)
                    context.addPath(path)
                    context.fillPath()
                    context.restoreGState()
                    context.addPath(path)
                    context.strokePath()
                }

            case .ellipse(let rect):
                let cRect = contextRect(rect, imageHeight: imageHeight)
                switch annotation.shapeFillMode {
                case .none:
                    context.strokeEllipse(in: cRect)
                case .opaque:
                    context.fillEllipse(in: cRect)
                case .translucent:
                    context.saveGState()
                    context.setFillColor(annotation.color.cgColor.copy(alpha: 0.28) ?? color)
                    context.fillEllipse(in: cRect)
                    context.restoreGState()
                    context.strokeEllipse(in: cRect)
                }

            case .highlight(let points):
                drawHighlight(points, color: annotation.color, brushWidth: annotation.highlightBrushWidth, in: context, imageHeight: imageHeight)

            case .spotlight:
                // 见 `render`：所有聚光灯合成一层，最后统一画。
                break

            case .arrow(let from, let to, let control):
                drawArrow(
                    from: from,
                    to: to,
                    control: control,
                    style: annotation.arrowStyle,
                    lineWidth: annotation.lineWidth,
                    color: annotation.color,
                    in: context,
                    imageHeight: imageHeight
                )

            case .line(let from, let to):
                context.move(to: contextPoint(from, imageHeight: imageHeight))
                context.addLine(to: contextPoint(to, imageHeight: imageHeight))
                context.strokePath()

            case .pen(let points):
                drawPen(points, in: context, imageHeight: imageHeight)

            case .text(let origin, let string, let fontSize):
                drawText(
                    string,
                    topLeft: origin,
                    fontSize: fontSize,
                    color: annotation.color,
                    hasStroke: annotation.textHasStroke,
                    hasCallout: annotation.textHasCallout,
                    in: context,
                    imageHeight: imageHeight
                )

            case .pixelate(let rect, let block):
                drawMosaic(
                    rect,
                    block: block,
                    base: base,
                    mosaic: mosaic,
                    in: context,
                    imageHeight: imageHeight
                )

            case .blur(let rect, let radius):
                drawBlur(
                    rect,
                    radius: radius,
                    base: base,
                    in: context,
                    imageHeight: imageHeight
                )

            case .counter(let center, let value, let leader):
                drawCounter(
                    value,
                    center: center,
                    leader: leader,
                    radius: max(12, annotation.lineWidth * 4),
                    color: annotation.color,
                    in: context,
                    imageHeight: imageHeight
                )

            case .callout(let center, let value, let labelOrigin, let string, let fontSize):
                drawCallout(
                    annotation,
                    center: center,
                    value: value,
                    labelOrigin: labelOrigin,
                    string: string,
                    fontSize: fontSize,
                    in: context,
                    imageHeight: imageHeight
                )

            case .eraser(let points, let radius):
                drawEraser(
                    points,
                    radius: radius,
                    base: base,
                    in: context,
                    imageHeight: imageHeight
                )
            }
        }

        if annotation.rotation != 0 {
            let centerPoint = contextPoint(annotation.center, imageHeight: imageHeight)
            context.saveGState()
            context.translateBy(x: centerPoint.x, y: centerPoint.y)
            context.rotate(by: -annotation.rotation)
            context.translateBy(x: -centerPoint.x, y: -centerPoint.y)
            body()
            context.restoreGState()
        } else {
            body()
        }
    }

    // MARK: - 箭头

    /// 箭头几何：与 capcap 的 `ArrowAnnotation.arrowGeometry` 同一套算法。
    ///
    /// 关键一点：**曲线箭头**（拖过曲线手柄）的头部方向取端点切线，而不是起终点连线，
    /// 否则弯箭头的头会指着弦的方向、看着是歪的。
    private struct ArrowGeometry {
        let start: CGPoint
        let end: CGPoint
        /// 曲线手柄；nil = 直箭头。
        let control: CGPoint?
        /// 起 / 终点的切线单位向量。
        let startUnit: CGVector
        let endUnit: CGVector
        /// 起终点直线距离（判断「小箭头」用它，不用切线长度）。
        let span: CGFloat
        /// 终点切线长度（|终点 − 控制点|），de Casteljau 截断用。
        let endTangentLength: CGFloat
    }

    private static func arrowGeometry(
        start: CGPoint,
        end: CGPoint,
        control: CGPoint?
    ) -> ArrowGeometry? {
        let span = hypot(end.x - start.x, end.y - start.y)
        guard span > 0.5 else { return nil }
        let chord = CGVector(dx: (end.x - start.x) / span, dy: (end.y - start.y) / span)

        func unitVector(from a: CGPoint, to b: CGPoint) -> CGVector? {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length = hypot(dx, dy)
            guard length > 0.0001 else { return nil }
            return CGVector(dx: dx / length, dy: dy / length)
        }

        // 二次曲线在端点的切线：起点是「起点 → 控制点」，终点是「控制点 → 终点」。
        let endUnit = control.flatMap { unitVector(from: $0, to: end) } ?? chord
        let startUnit = control.flatMap { unitVector(from: $0, to: start) } ?? chord
        let endTangentLength = control.map { max(hypot(end.x - $0.x, end.y - $0.y), 0.0001) } ?? span
        return ArrowGeometry(
            start: start,
            end: end,
            control: control,
            startUnit: startUnit,
            endUnit: endUnit,
            span: span,
            endTangentLength: endTangentLength
        )
    }

    private static func drawArrow(
        from: CGPoint,
        to: CGPoint,
        control: CGPoint?,
        style: ArrowStyle = .tapered,
        lineWidth: CGFloat,
        color: RGBAColor,
        in context: CGContext,
        imageHeight: Int
    ) {
        let start = contextPoint(from, imageHeight: imageHeight)
        let end = contextPoint(to, imageHeight: imageHeight)
        let bend = control.map { contextPoint($0, imageHeight: imageHeight) }

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        defer { context.restoreGState() }

        guard let geometry = arrowGeometry(start: start, end: end, control: bend) else { return }
        switch style {
        case .tapered:
            drawTaperedArrow(geometry, lineWidth: lineWidth, in: context)
        case .doubleEnded, .line, .dotTail:
            drawStrokedArrow(geometry, style: style, lineWidth: lineWidth, in: context)
        }
    }

    /// 渐宽实心箭头（capcap 的 `drawTapered`）：
    /// 直箭头是一个 7 顶点「水滴」——尾端细、到颈部收窄、再展开成后掠的三角头；
    /// 弯箭头则是两条按局部法线偏移的二次曲线围成的带子 + 5 顶点后掠头。
    private static func drawTaperedArrow(
        _ geometry: ArrowGeometry,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        var headLength = max(22, lineWidth * 6.5)
        var headWidth = max(22, lineWidth * 7.5)
        var neckHalf = max(3, lineWidth * 1.4)
        var tailHalf = max(0.5, lineWidth * 0.25)

        // 小箭头整体等比缩小：头不会长过尾巴，多边形也不会自交。
        // （之前是给头长 / 头宽各自 min(..., 弦长 × 系数)，那样短箭头会被压成一个歪头。）
        if geometry.span < headLength {
            let scale = geometry.span / headLength
            headWidth *= scale
            neckHalf *= scale
            tailHalf *= scale
            headLength = geometry.span
        }

        // 颈部比头根更靠箭尖一点，头部因此是「后掠」的，不是一块直边三角。
        let neckIndent = headLength * 0.14
        let endUnit = geometry.endUnit
        let perp = CGVector(dx: -endUnit.dy, dy: endUnit.dx)
        let base = CGPoint(
            x: geometry.end.x - endUnit.dx * headLength,
            y: geometry.end.y - endUnit.dy * headLength
        )
        let neck = CGPoint(
            x: geometry.end.x - endUnit.dx * (headLength - neckIndent),
            y: geometry.end.y - endUnit.dy * (headLength - neckIndent)
        )

        func offset(_ point: CGPoint, _ normal: CGVector, _ distance: CGFloat) -> CGPoint {
            CGPoint(x: point.x + normal.dx * distance, y: point.y + normal.dy * distance)
        }

        let headLeft = offset(base, perp, headWidth / 2)
        let headRight = offset(base, perp, -headWidth / 2)
        let neckLeft = offset(neck, perp, neckHalf)
        let neckRight = offset(neck, perp, -neckHalf)
        let tailLeft = offset(geometry.start, perp, tailHalf)
        let tailRight = offset(geometry.start, perp, -tailHalf)

        context.beginPath()
        if let bend = geometry.control {
            // 箭身是「两条偏移二次曲线」围成的带子。等距偏移二次曲线没有简单闭式解，
            // 这里和 capcap 一样，在三个控制点上各按局部法线偏移（笔宽很小，近似足够）；
            // 控制点再用 de Casteljau 截断到颈部，否则带子会鼓到原始曲线之外。
            let startUnit = geometry.startUnit
            let startPerp = CGVector(dx: -startUnit.dy, dy: startUnit.dx)
            let chordPerp = CGVector(
                dx: -(geometry.end.y - geometry.start.y) / geometry.span,
                dy: (geometry.end.x - geometry.start.x) / geometry.span
            )
            let neckDistance = headLength - neckIndent
            let t = max(0, min(1, 1 - neckDistance / (2 * geometry.endTangentLength)))
            let truncated = CGPoint(
                x: geometry.start.x + (bend.x - geometry.start.x) * t,
                y: geometry.start.y + (bend.y - geometry.start.y) * t
            )
            let midHalf = (tailHalf + neckHalf) / 2

            context.move(to: offset(geometry.start, startPerp, tailHalf))
            context.addQuadCurve(to: neckLeft, control: offset(truncated, chordPerp, midHalf))
            context.addLine(to: neckRight)
            context.addQuadCurve(
                to: offset(geometry.start, startPerp, -tailHalf),
                control: offset(truncated, chordPerp, -midHalf)
            )
            context.closePath()
            context.fillPath()

            context.beginPath()
            context.move(to: geometry.end)
            context.addLine(to: headLeft)
            context.addLine(to: neckLeft)
            context.addLine(to: neckRight)
            context.addLine(to: headRight)
            context.closePath()
            context.fillPath()
        } else {
            context.move(to: geometry.end)
            context.addLine(to: headLeft)
            context.addLine(to: neckLeft)
            context.addLine(to: tailLeft)
            context.addLine(to: tailRight)
            context.addLine(to: neckRight)
            context.addLine(to: headRight)
            context.closePath()
            context.fillPath()
        }
    }

    /// 描边箭头（capcap 的 `drawStroked`）：主干线 + 实心三角头，头按线宽比例做圆角描边。
    /// 双向箭头两端各一个头，圆点箭头尾部一个实心点。
    private static func drawStrokedArrow(
        _ geometry: ArrowGeometry,
        style: ArrowStyle,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        let shaftWidth = max(1, lineWidth)
        let headLimit: CGFloat = style == .doubleEnded ? 0.34 : 0.46
        let headLength = min(max(10, shaftWidth * 4), max(4, geometry.span * headLimit))
        let headWidth = min(max(7, shaftWidth * 3), max(6, geometry.span * 0.75))
        let tailRadius: CGFloat = style == .dotTail ? max(4, shaftWidth + 2) : 0

        // 主干两端让出箭头长度（双向箭头两头都让）；太长就等比缩，免得杆子穿出箭头。
        var startInset: CGFloat = style == .doubleEnded ? headLength : 0
        var endInset = headLength
        let totalInset = startInset + endInset
        if totalInset > geometry.span - 1, totalInset > 0 {
            let scale = max(0, geometry.span - 1) / totalInset
            startInset *= scale
            endInset *= scale
        }
        let spineStart = CGPoint(
            x: geometry.start.x + geometry.startUnit.dx * startInset,
            y: geometry.start.y + geometry.startUnit.dy * startInset
        )
        let spineEnd = CGPoint(
            x: geometry.end.x - geometry.endUnit.dx * endInset,
            y: geometry.end.y - geometry.endUnit.dy * endInset
        )

        context.beginPath()
        context.move(to: spineStart)
        if let bend = geometry.control {
            context.addQuadCurve(to: spineEnd, control: bend)
        } else {
            context.addLine(to: spineEnd)
        }
        context.setLineWidth(shaftWidth)
        context.strokePath()

        if style == .dotTail {
            context.fillEllipse(
                in: CGRect(
                    x: geometry.start.x - tailRadius,
                    y: geometry.start.y - tailRadius,
                    width: tailRadius * 2,
                    height: tailRadius * 2
                )
            )
        }

        // 头的尖角靠这一圈圆角描边变圆润（capcap 固定 1.5；我们按线宽走，粗箭头才不显尖）。
        let headStroke = max(1.5, lineWidth * 0.5)
        fillArrowHead(
            tip: geometry.end,
            unit: geometry.endUnit,
            length: headLength,
            width: headWidth,
            strokeWidth: headStroke,
            in: context
        )
        if style == .doubleEnded {
            fillArrowHead(
                tip: geometry.start,
                unit: CGVector(dx: -geometry.startUnit.dx, dy: -geometry.startUnit.dy),
                length: headLength,
                width: headWidth,
                strokeWidth: headStroke,
                in: context
            )
        }
    }

    /// 实心三角箭头：填充 + 圆角描边，尖角不会像纯填充那样「削尖」。
    private static func fillArrowHead(
        tip: CGPoint,
        unit: CGVector,
        length: CGFloat,
        width: CGFloat,
        strokeWidth: CGFloat,
        in context: CGContext
    ) {
        let perp = CGVector(dx: -unit.dy, dy: unit.dx)
        let base = CGPoint(x: tip.x - unit.dx * length, y: tip.y - unit.dy * length)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x + perp.dx * width / 2, y: base.y + perp.dy * width / 2))
        path.addLine(to: CGPoint(x: base.x - perp.dx * width / 2, y: base.y - perp.dy * width / 2))
        path.closeSubpath()

        context.saveGState()
        context.setLineJoin(.round)
        context.setLineWidth(strokeWidth)
        context.addPath(path)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    private static func drawPen(_ points: [CGPoint], in context: CGContext, imageHeight: Int) {
        guard points.count > 1 else {
            if let point = points.first {
                let center = contextPoint(point, imageHeight: imageHeight)
                context.fillEllipse(
                    in: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)
                )
            }
            return
        }
        context.move(to: contextPoint(points[0], imageHeight: imageHeight))
        for point in points.dropFirst() {
            context.addLine(to: contextPoint(point, imageHeight: imageHeight))
        }
        context.strokePath()
    }

    /// 荧光笔：一条半透明的粗笔迹。
    ///
    /// 两处照 capcap 的高亮笔来做：
    /// 1. 笔迹按「中点二次曲线」平滑，急转弯处不会是硬折角；
    /// 2. 整条笔迹先以**不透明**画进一个透明层，再让整层按 `highlightAlpha` 合成 ——
    ///    这样自己叠自己（来回涂、拐弯重叠）不会越涂越深。
    private static func drawHighlight(
        _ points: [CGPoint],
        color: RGBAColor,
        brushWidth: CGFloat,
        in context: CGContext,
        imageHeight: Int
    ) {
        guard !points.isEmpty, brushWidth > 0 else { return }
        // 鼠标停住时会一直上报同一个点，先并掉：既省事，也避免「单击」被当成一条零长笔迹。
        let cgPoints = Annotation.deduplicated(points.map { contextPoint($0, imageHeight: imageHeight) })
        guard let first = cgPoints.first else { return }
        let opaque = color.cgColor.copy(alpha: 1) ?? color.cgColor

        context.saveGState()
        context.setStrokeColor(opaque)
        context.setFillColor(opaque)
        context.setLineWidth(brushWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setAlpha(Annotation.highlightAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        if cgPoints.count == 1 {
            // 单击 = 笔尖按下的一个圆点。
            let radius = brushWidth / 2
            context.fillEllipse(
                in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)
            )
        } else {
            context.addPath(smoothedPolyline(cgPoints))
            context.strokePath()
        }

        context.endTransparencyLayer()
        context.setAlpha(1)
        context.restoreGState()
    }

    /// 中点二次曲线平滑：每个原始点当控制点，锚点取相邻两点的中点。
    /// 与 capcap 的 `NSBezierPath.smoothed(through:)` 是同一套算法。
    ///
    /// 入参需先经 `deduplicated`（相邻重复点会让中点重合）。
    private static func smoothedPolyline(_ raw: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = raw.first else { return path }
        path.move(to: first)
        guard raw.count > 1 else { return path }
        if raw.count == 2 {
            path.addLine(to: raw[1])
            return path
        }

        // 注意「退化二次曲线」：当相邻两个中点重合（笔迹原路折返）时，这条曲线的起点
        // 与终点是同一个点，CoreGraphics 遇到这种段会**整条路径都不画**（笔迹凭空消失）。
        // 折返时改画「走到折返点再折回来」，笔迹照样盖住用户画到的最远处。
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }

        var cursor = first
        let firstAnchor = mid(raw[0], raw[1])
        path.addLine(to: firstAnchor)
        cursor = firstAnchor

        for index in 1..<(raw.count - 1) {
            let control = raw[index]
            let anchor = mid(raw[index], raw[index + 1])
            if Annotation.isSamePoint(cursor, anchor) {
                guard !Annotation.isSamePoint(cursor, control) else { continue }
                path.addLine(to: control)
                cursor = control
            } else {
                path.addQuadCurve(to: anchor, control: control)
                cursor = anchor
            }
        }
        let last = raw[raw.count - 1]
        if !Annotation.isSamePoint(cursor, last) {
            path.addLine(to: last)
        }
        return path
    }

    /// 聚光灯：整幅压暗，只留窗口内清晰。
    ///
    /// 用一张灰度遮罩（窗口处为黑、其余为白）走 `clip(to:mask:)` 再铺一层黑，
    /// 而不是「先铺黑、再用 `.clear` 抠洞」：抠洞会把已经画好的底图与标注一起抹掉；
    /// 遮罩是取并集，多个窗口重叠时也不会互相抵消。
    private static func drawSpotlight(_ rects: [CGRect], in context: CGContext, imageHeight: Int) {
        let bounds = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let holes = rects.map { contextRect($0, imageHeight: imageHeight) }
        guard
            let mask = spotlightMask(width: context.width, height: context.height, holes: holes)
        else { return }

        context.saveGState()
        context.clip(to: bounds, mask: mask)
        context.setFillColor(
            CGColor(srgbRed: 0, green: 0, blue: 0, alpha: Annotation.spotlightDimAlpha)
        )
        context.fill(bounds)
        context.restoreGState()
    }

    /// 聚光灯遮罩：白 = 压暗，黑 = 透出（窗口）。
    private static func spotlightMask(width: Int, height: Int, holes: [CGRect]) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for hole in holes {
            guard hole.width > 0, hole.height > 0 else { continue }
            let radius = min(Annotation.spotlightCornerRadius, hole.width / 2, hole.height / 2)
            context.addPath(
                CGPath(roundedRect: hole, cornerWidth: radius, cornerHeight: radius, transform: nil)
            )
            context.fillPath()
        }
        return context.makeImage()
    }

    private static func drawText(
        _ string: String,
        topLeft: CGPoint,
        fontSize: CGFloat,
        color: RGBAColor,
        hasStroke: Bool = false,
        hasCallout: Bool = false,
        in context: CGContext,
        imageHeight: Int
    ) {
        guard !string.isEmpty, fontSize > 0 else { return }
        let font = Annotation.systemFont(fontSize: fontSize)
        let line = makeLine(string, font: font, color: color)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent

        let textY = CGFloat(imageHeight) - (topLeft.y + ascent)

        // 标注特效：绘制背景底板气泡
        if hasCallout {
            let paddingH: CGFloat = max(6, fontSize * 0.35)
            let paddingV: CGFloat = max(3, fontSize * 0.2)
            let bgRect = CGRect(
                x: topLeft.x - paddingH,
                y: textY - descent - paddingV,
                width: width + paddingH * 2,
                height: height + paddingV * 2
            )
            context.saveGState()
            context.setFillColor(color.cgColor)
            let cornerRadius = min(8, bgRect.height / 3)
            let path = CGPath(
                roundedRect: bgRect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
            context.addPath(path)
            context.fillPath()
            context.restoreGState()

            // 标注底板为纯色时，文字使用高对比白色（浅底用黑）
            let lum = 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
            let textColor = lum > 0.65 ? RGBAColor.black : RGBAColor.white
            let contrastLine = makeLine(string, font: font, color: textColor)
            context.textPosition = CGPoint(x: topLeft.x, y: textY)
            CTLineDraw(contrastLine, context)
            return
        }

        // 描边特效：先描一圈高对比边框，再填字
        if hasStroke {
            let lum = 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
            let strokeColor = lum > 0.65 ? RGBAColor.black.cgColor : RGBAColor.white.cgColor
            let strokeWidth = max(2.5, fontSize * 0.14)

            context.saveGState()
            context.setTextDrawingMode(.stroke)
            context.setStrokeColor(strokeColor)
            context.setLineWidth(strokeWidth)
            context.setLineJoin(.round)
            context.textPosition = CGPoint(x: topLeft.x, y: textY)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        context.saveGState()
        context.setTextDrawingMode(.fill)
        context.textPosition = CGPoint(x: topLeft.x, y: textY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawCallout(
        _ annotation: Annotation,
        center: CGPoint,
        value: Int,
        labelOrigin: CGPoint,
        string: String,
        fontSize: CGFloat,
        in context: CGContext,
        imageHeight: Int
    ) {
        let color = annotation.color
        // 圆点沿用之前的大小。
        let radius = max(12, annotation.lineWidth * 4)
        let dotCenter = contextPoint(center, imageHeight: imageHeight)
        let labelRect = Annotation.calloutLabelRect(
            origin: labelOrigin,
            string: string,
            fontSize: fontSize
        )
        let contextLabelRect = contextRect(labelRect, imageHeight: imageHeight)
        let corner: CGFloat = 10

        context.setFillColor(color.cgColor)

        // 尾巴：贴在最靠近圆点的那条边上，尖端指向圆点（无缝隙）。
        let rectCenter = CGPoint(x: labelRect.midX, y: labelRect.midY)
        let dx = center.x - rectCenter.x
        let dy = center.y - rectCenter.y
        let tailLength: CGFloat = 14
        let halfBase: CGFloat = 7
        var baseA = CGPoint.zero
        var baseB = CGPoint.zero
        var tip = CGPoint.zero

        if abs(dx) >= abs(dy) {
            // 左右边
            let edgeX = dx < 0 ? labelRect.minX : labelRect.maxX
            let edgeY = min(max(center.y, labelRect.minY + halfBase + 2), labelRect.maxY - halfBase - 2)
            baseA = CGPoint(x: edgeX, y: edgeY - halfBase)
            baseB = CGPoint(x: edgeX, y: edgeY + halfBase)
            tip = CGPoint(x: edgeX + (dx < 0 ? -tailLength : tailLength), y: edgeY)
        } else {
            // 上下边
            let edgeY = dy < 0 ? labelRect.minY : labelRect.maxY
            let edgeX = min(max(center.x, labelRect.minX + halfBase + 2), labelRect.maxX - halfBase - 2)
            baseA = CGPoint(x: edgeX - halfBase, y: edgeY)
            baseB = CGPoint(x: edgeX + halfBase, y: edgeY)
            tip = CGPoint(x: edgeX, y: edgeY + (dy < 0 ? -tailLength : tailLength))
        }

        let triangle = CGMutablePath()
        triangle.move(to: contextPoint(baseA, imageHeight: imageHeight))
        triangle.addLine(to: contextPoint(tip, imageHeight: imageHeight))
        triangle.addLine(to: contextPoint(baseB, imageHeight: imageHeight))
        triangle.closeSubpath()
        context.addPath(triangle)
        context.fillPath()

        // 气泡本体。
        context.addPath(
            CGPath(
                roundedRect: contextLabelRect,
                cornerWidth: corner,
                cornerHeight: corner,
                transform: nil
            )
        )
        context.fillPath()
        if !string.isEmpty {
            drawCenteredText(
                string,
                in: contextLabelRect,
                fontSize: fontSize,
                color: .white,
                context: context
            )
        }

        // 序号圆点。
        context.fillEllipse(
            in: CGRect(
                x: dotCenter.x - radius,
                y: dotCenter.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, radius * 1.1, nil)
        let line = makeLine("\(value)", font: font, color: .white)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.textPosition = CGPoint(
            x: dotCenter.x - width / 2,
            y: dotCenter.y - (ascent - descent) / 2
        )
        CTLineDraw(line, context)
    }

    /// 在矩形内居中绘制一行文字。
    private static func drawCenteredText(
        _ string: String,
        in rect: CGRect,
        fontSize: CGFloat,
        color: RGBAColor,
        context: CGContext
    ) {
        let font = Annotation.systemFont(fontSize: fontSize)
        let line = makeLine(string, font: font, color: color)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.textPosition = CGPoint(
            x: rect.midX - width / 2,
            y: rect.midY - (ascent - descent) / 2
        )
        CTLineDraw(line, context)
    }

    private static func drawCounter(
        _ value: Int,
        center: CGPoint,
        leader: CGPoint?,
        radius: CGFloat,
        color: RGBAColor,
        in context: CGContext,
        imageHeight: Int
    ) {
        let centerPoint = contextPoint(center, imageHeight: imageHeight)

        if let leader {
            context.setStrokeColor(color.cgColor)
            context.move(to: contextPoint(leader, imageHeight: imageHeight))
            context.addLine(to: centerPoint)
            context.strokePath()
        }

        context.setFillColor(color.cgColor)
        context.fillEllipse(
            in: CGRect(
                x: centerPoint.x - radius,
                y: centerPoint.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, radius * 1.1, nil)
        let line = makeLine("\(value)", font: font, color: .white)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.textPosition = CGPoint(
            x: centerPoint.x - width / 2,
            y: centerPoint.y - (ascent - descent) / 2
        )
        CTLineDraw(line, context)
    }

    private static func drawMosaic(
        _ rect: CGRect,
        block: CGFloat,
        base: CGImage,
        mosaic: (CGFloat) -> CGImage?,
        in context: CGContext,
        imageHeight: Int
    ) {
        let blockSize = max(2, block)
        guard let mosaicImage = mosaic(blockSize), mosaicImage.width > 0, mosaicImage.height > 0
        else { return }
        let scaleX = CGFloat(mosaicImage.width) / CGFloat(base.width)
        let scaleY = CGFloat(mosaicImage.height) / CGFloat(base.height)
        let source = CGRect(
            x: rect.minX * scaleX,
            y: rect.minY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        .integral
        .intersection(
            CGRect(x: 0, y: 0, width: mosaicImage.width, height: mosaicImage.height)
        )
        guard !source.isEmpty, let crop = mosaicImage.cropping(to: source) else { return }

        context.saveGState()
        context.interpolationQuality = .none
        context.draw(crop, in: contextRect(rect, imageHeight: imageHeight))
        context.restoreGState()
    }

    /// 高斯模糊：对底图对应的那块做 CIGaussianBlur，再按矩形裁回。
    private static func drawBlur(
        _ rect: CGRect,
        radius: CGFloat,
        base: CGImage,
        in context: CGContext,
        imageHeight: Int
    ) {
        let target = contextRect(rect, imageHeight: imageHeight).integral
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        // 模糊会向外扩散，多取一圈再裁回来，避免边缘发虚。
        let padding = max(2, radius * 2)
        let source = target.insetBy(dx: -padding, dy: -padding).intersection(bounds)
        guard !source.isEmpty, let filter = CIFilter(name: "CIGaussianBlur") else { return }

        filter.setValue(CIImage(cgImage: base).cropped(to: source), forKey: kCIInputImageKey)
        filter.setValue(max(1, radius), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: source),
            let blurred = ciContext.createCGImage(output, from: source)
        else { return }

        context.saveGState()
        context.clip(to: target)
        context.draw(blurred, in: source)
        context.restoreGState()
    }

    private static func drawEraser(
        _ points: [CGPoint],
        radius: CGFloat,
        base: CGImage,
        in context: CGContext,
        imageHeight: Int
    ) {
        guard !points.isEmpty, radius > 0 else { return }
        let cgPoints = points.map { contextPoint($0, imageHeight: imageHeight) }
        guard let first = cgPoints.first else { return }
        context.saveGState()
        context.beginPath()
        if cgPoints.count == 1 {
            context.addEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
        } else {
            var hasMovement = false
            for pt in cgPoints.dropFirst() {
                if abs(pt.x - first.x) > 0.1 || abs(pt.y - first.y) > 0.1 {
                    hasMovement = true
                    break
                }
            }
            if !hasMovement {
                context.addEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
            } else {
                context.move(to: first)
                for pt in cgPoints.dropFirst() {
                    context.addLine(to: pt)
                }
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.setLineWidth(max(2, radius * 2))
                context.replacePathWithStrokedPath()
            }
        }
        context.clip()
        context.setBlendMode(.copy)
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: imageHeight))
        context.restoreGState()
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func makeLine(_ string: String, font: CTFont, color: RGBAColor) -> CTLine {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor,
        ]
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)!
        return CTLineCreateWithAttributedString(attributed)
    }

    // MARK: - Coordinate conversion

    private static func contextRect(_ rect: CGRect, imageHeight: Int) -> CGRect {
        CGRect(
            x: rect.minX,
            y: CGFloat(imageHeight) - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 矩形描边 / 填充用的路径：方角就是矩形本体，圆角按短边比例倒角。
    static func rectanglePath(_ rect: CGRect, style: RectCornerStyle) -> CGPath {
        let radius = RectCornerStyle.radius(for: rect, style: style)
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }

    private static func contextPoint(_ point: CGPoint, imageHeight: Int) -> CGPoint {
        CGPoint(x: point.x, y: CGFloat(imageHeight) - point.y)
    }
}
