import AppKit

/// 标注渲染 — 箭头几何与绘制。
///
/// @author ixxxxoooo
extension AnnotationRenderer {

    /// 箭头几何：与 capcap 的 `ArrowAnnotation.arrowGeometry` 同一套算法。
    ///
    /// 关键一点：**曲线箭头**（拖过曲线手柄）的头部方向取端点切线，而不是起终点连线，
    /// 否则弯箭头的头会指着弦的方向、看着是歪的。
    struct ArrowGeometry {
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

    static func arrowGeometry(
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

    static func drawArrow(
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
    static func drawTaperedArrow(
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
    static func drawStrokedArrow(
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
    static func fillArrowHead(
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

}
