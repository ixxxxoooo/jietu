import CoreGraphics
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

    /// 渲染底图 + 标注。
    static func render(base: CGImage, annotations: [Annotation]) -> CGImage? {
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
        for annotation in annotations {
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
                context.stroke(contextRect(rect, imageHeight: imageHeight))

            case .ellipse(let rect):
                context.strokeEllipse(in: contextRect(rect, imageHeight: imageHeight))

            case .highlight(let rect):
                context.saveGState()
                context.setFillColor(
                    annotation.color.cgColor.copy(alpha: 0.35) ?? color
                )
                context.fill(contextRect(rect, imageHeight: imageHeight))
                context.restoreGState()

            case .arrow(let from, let to, let control):
                drawArrow(
                    from: from,
                    to: to,
                    control: control,
                    lineWidth: annotation.lineWidth,
                    in: context,
                    imageHeight: imageHeight
                )

            case .pen(let points):
                drawPen(points, in: context, imageHeight: imageHeight)

            case .text(let origin, let string, let fontSize):
                drawText(
                    string,
                    topLeft: origin,
                    fontSize: fontSize,
                    color: annotation.color,
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
        lineWidth: CGFloat,
        in context: CGContext,
        imageHeight: Int
    ) {
        let start = contextPoint(from, imageHeight: imageHeight)
        let end = contextPoint(to, imageHeight: imageHeight)

        var tangent: CGPoint
        if let control {
            let c = contextPoint(control, imageHeight: imageHeight)
            context.move(to: start)
            context.addQuadCurve(to: end, control: c)
            context.strokePath()
            tangent = CGPoint(x: end.x - c.x, y: end.y - c.y)
        } else {
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            tangent = CGPoint(x: end.x - start.x, y: end.y - start.y)
        }

        let angle = atan2(tangent.y, tangent.x)
        let headLength = max(12, lineWidth * 5)
        let spread = CGFloat.pi / 7
        for offset in [CGFloat.pi - spread, CGFloat.pi + spread] {
            let point = CGPoint(
                x: end.x + cos(angle + offset) * headLength,
                y: end.y + sin(angle + offset) * headLength
            )
            context.move(to: end)
            context.addLine(to: point)
        }
        context.strokePath()
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

    private static func drawText(
        _ string: String,
        topLeft: CGPoint,
        fontSize: CGFloat,
        color: RGBAColor,
        in context: CGContext,
        imageHeight: Int
    ) {
        guard !string.isEmpty, fontSize > 0 else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let ascent = CTFontGetAscent(font)
        context.textPosition = CGPoint(
            x: topLeft.x,
            y: CGFloat(imageHeight) - topLeft.y - ascent
        )
        CTLineDraw(makeLine(string, font: font, color: color), context)
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
        let radius: CGFloat = 12
        let dotCenter = contextPoint(center, imageHeight: imageHeight)
        let labelRect = Annotation.calloutLabelRect(
            origin: labelOrigin,
            string: string,
            fontSize: fontSize
        )
        let contextLabelRect = contextRect(labelRect, imageHeight: imageHeight)
        let corner: CGFloat = 10

        // 小尾巴：从气泡边缘指向序号圆点（iMessage 那种气泡）。
        let edge = CGPoint(
            x: min(max(center.x, labelRect.minX), labelRect.maxX),
            y: min(max(center.y, labelRect.minY), labelRect.maxY)
        )
        let edgeContext = contextPoint(edge, imageHeight: imageHeight)
        let dx = dotCenter.x - edgeContext.x
        let dy = dotCenter.y - edgeContext.y
        let length = max(1, hypot(dx, dy))
        let ux = dx / length
        let uy = dy / length
        let tailLength = min(14, length)
        let tip = CGPoint(x: edgeContext.x + ux * tailLength, y: edgeContext.y + uy * tailLength)
        let halfBase: CGFloat = 7
        let baseA = CGPoint(x: edgeContext.x - uy * halfBase, y: edgeContext.y + ux * halfBase)
        let baseB = CGPoint(x: edgeContext.x + uy * halfBase, y: edgeContext.y - ux * halfBase)
        context.setFillColor(color.cgColor)
        context.beginPath()
        context.move(to: baseA)
        context.addLine(to: tip)
        context.addLine(to: baseB)
        context.closePath()
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
        context.setFillColor(color.cgColor)
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
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
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
