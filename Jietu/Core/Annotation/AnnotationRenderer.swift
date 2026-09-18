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
    static func render(
        base: CGImage,
        annotations: [Annotation],
        eraserStrokes: [EraserStroke] = []
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
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

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
                switch annotation.shapeFillMode {
                case .none:
                    context.stroke(cRect)
                case .opaque:
                    context.fill(cRect)
                case .translucent:
                    context.saveGState()
                    context.setFillColor(annotation.color.cgColor.copy(alpha: 0.28) ?? color)
                    context.fill(cRect)
                    context.restoreGState()
                    context.stroke(cRect)
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

        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else {
            context.restoreGState()
            return
        }

        let ux = dx / length
        let uy = dy / length
        let nx = -uy
        let ny = ux

        switch style {
        case .tapered:
            // capcap 风格的渐宽实心箭头（7 顶点闭合多边形，尾端圆角微缩，箭身渐宽，头部展翼后收于顶点）
            let headLength = min(max(lineWidth * 5.0, 18.0), length * 0.46)
            let headWidth = min(max(lineWidth * 3.4, 14.0), length * 0.40)
            let neckWidth = min(max(lineWidth * 1.1, 4.0), headWidth * 0.45)
            let tailWidth = min(max(lineWidth * 0.35, 1.8), neckWidth * 0.5)

            let neckBase = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
            let tip = end
            let rightBarb = CGPoint(x: neckBase.x + nx * (headWidth / 2), y: neckBase.y + ny * (headWidth / 2))
            let rightNeck = CGPoint(x: neckBase.x + nx * (neckWidth / 2), y: neckBase.y + ny * (neckWidth / 2))
            let rightTail = CGPoint(x: start.x + nx * (tailWidth / 2), y: start.y + ny * (tailWidth / 2))
            let leftTail = CGPoint(x: start.x - nx * (tailWidth / 2), y: start.y - ny * (tailWidth / 2))
            let leftNeck = CGPoint(x: neckBase.x - nx * (neckWidth / 2), y: neckBase.y - ny * (neckWidth / 2))
            let leftBarb = CGPoint(x: neckBase.x - nx * (headWidth / 2), y: neckBase.y - ny * (headWidth / 2))

            context.beginPath()
            context.move(to: tip)
            context.addLine(to: rightBarb)
            context.addLine(to: rightNeck)
            context.addLine(to: rightTail)
            context.addArc(
                center: start,
                radius: tailWidth / 2,
                startAngle: atan2(ny, nx),
                endAngle: atan2(-ny, -nx),
                clockwise: false
            )
            context.addLine(to: leftNeck)
            context.addLine(to: leftBarb)
            context.closePath()
            context.fillPath()

        case .doubleEnded:
            // 双向实心箭头：主干线 + 两端均为实心闭合三角箭头
            let headLength = min(max(lineWidth * 3.8, 14.0), length * 0.4)
            let headWidth = min(max(lineWidth * 3.0, 11.0), length * 0.35)

            let startNeck = CGPoint(x: start.x + ux * (headLength * 0.7), y: start.y + uy * (headLength * 0.7))
            let endNeck = CGPoint(x: end.x - ux * (headLength * 0.7), y: end.y - uy * (headLength * 0.7))

            context.setLineWidth(lineWidth)
            context.beginPath()
            context.move(to: startNeck)
            context.addLine(to: endNeck)
            context.strokePath()

            // 起点箭头（向后指）
            let sBarb1 = CGPoint(x: start.x + ux * headLength + nx * (headWidth / 2), y: start.y + uy * headLength + ny * (headWidth / 2))
            let sBarb2 = CGPoint(x: start.x + ux * headLength - nx * (headWidth / 2), y: start.y + uy * headLength - ny * (headWidth / 2))
            context.beginPath()
            context.move(to: start)
            context.addLine(to: sBarb1)
            context.addLine(to: sBarb2)
            context.closePath()
            context.fillPath()

            // 终点箭头（向前指）
            let eBarb1 = CGPoint(x: end.x - ux * headLength + nx * (headWidth / 2), y: end.y - uy * headLength + ny * (headWidth / 2))
            let eBarb2 = CGPoint(x: end.x - ux * headLength - nx * (headWidth / 2), y: end.y - uy * headLength - ny * (headWidth / 2))
            context.beginPath()
            context.move(to: end)
            context.addLine(to: eBarb1)
            context.addLine(to: eBarb2)
            context.closePath()
            context.fillPath()

        case .line:
            // 直箭头：主干线 + 终点实心闭合三角箭头
            let headLength = min(max(lineWidth * 3.8, 14.0), length * 0.45)
            let headWidth = min(max(lineWidth * 3.0, 11.0), length * 0.4)
            let endNeck = CGPoint(x: end.x - ux * (headLength * 0.7), y: end.y - uy * (headLength * 0.7))

            context.setLineWidth(lineWidth)
            context.beginPath()
            context.move(to: start)
            context.addLine(to: endNeck)
            context.strokePath()

            let eBarb1 = CGPoint(x: end.x - ux * headLength + nx * (headWidth / 2), y: end.y - uy * headLength + ny * (headWidth / 2))
            let eBarb2 = CGPoint(x: end.x - ux * headLength - nx * (headWidth / 2), y: end.y - uy * headLength - ny * (headWidth / 2))
            context.beginPath()
            context.move(to: end)
            context.addLine(to: eBarb1)
            context.addLine(to: eBarb2)
            context.closePath()
            context.fillPath()

        case .dotTail:
            // 圆点实心箭头：起点实心圆点 + 主干线 + 终点实心闭合三角箭头
            let dotRadius = max(lineWidth * 0.9, 4.0)
            context.fillEllipse(
                in: CGRect(
                    x: start.x - dotRadius,
                    y: start.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
            )

            let headLength = min(max(lineWidth * 3.8, 14.0), length * 0.45)
            let headWidth = min(max(lineWidth * 3.0, 11.0), length * 0.4)
            let endNeck = CGPoint(x: end.x - ux * (headLength * 0.7), y: end.y - uy * (headLength * 0.7))

            context.setLineWidth(lineWidth)
            context.beginPath()
            context.move(to: start)
            context.addLine(to: endNeck)
            context.strokePath()

            let eBarb1 = CGPoint(x: end.x - ux * headLength + nx * (headWidth / 2), y: end.y - uy * headLength + ny * (headWidth / 2))
            let eBarb2 = CGPoint(x: end.x - ux * headLength - nx * (headWidth / 2), y: end.y - uy * headLength - ny * (headWidth / 2))
            context.beginPath()
            context.move(to: end)
            context.addLine(to: eBarb1)
            context.addLine(to: eBarb2)
            context.closePath()
            context.fillPath()
        }

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

    private static func contextPoint(_ point: CGPoint, imageHeight: Int) -> CGPoint {
        CGPoint(x: point.x, y: CGFloat(imageHeight) - point.y)
    }
}
