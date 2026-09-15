import CoreGraphics
import CoreText
import Foundation

/// 把一组标注烘焙进底图，得到可导出的新位图。
///
/// 只依赖 CoreGraphics/CoreText，便于脱离 UI 做像素级单测。
/// 输入输出的几何量都按**图像像素坐标、原点左上**处理；内部绘制时统一翻到
/// `CGContext` 的原点左下坐标系。
///
/// @author ixxxxoooo
enum AnnotationRenderer {
    /// 马赛克的块尺寸（像素）。预览与导出共用同一值，保证所见即所得。
    static let mosaicBlock: Int = 8

    /// 渲染底图 + 标注。失败返回 nil。
    ///
    /// - Parameter mosaicBlock: 马赛克块尺寸。预览时按预览比例传入，
    ///   保证预览与导出的马赛克观感一致。
    static func render(
        base: CGImage,
        annotations: [Annotation],
        mosaicBlock: Int = AnnotationRenderer.mosaicBlock
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

        let mosaic = downsample(base, factor: max(1, mosaicBlock))

        for annotation in annotations {
            draw(annotation, base: base, mosaic: mosaic, in: context, imageHeight: height)
        }
        return context.makeImage()
    }

    /// 生成马赛克底图（整图缩小 `factor` 倍）。
    ///
    /// 预览与导出都用它，避免「编辑时看到的效果和保存出来的不一样」。
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
        mosaic: CGImage?,
        in context: CGContext,
        imageHeight: Int
    ) {
        let color = annotation.color.cgColor
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.shape {
        case .rectangle(let rect):
            context.stroke(contextRect(rect, imageHeight: imageHeight))

        case .ellipse(let rect):
            context.strokeEllipse(in: contextRect(rect, imageHeight: imageHeight))

        case .arrow(let from, let to):
            drawArrow(from: from, to: to, lineWidth: annotation.lineWidth, in: context, imageHeight: imageHeight)

        case .text(let origin, let string, let fontSize):
            drawText(
                string,
                topLeft: origin,
                fontSize: fontSize,
                color: annotation.color,
                in: context,
                imageHeight: imageHeight
            )

        case .pixelate(let rect):
            drawMosaic(rect, base: base, mosaic: mosaic, in: context, imageHeight: imageHeight)

        case .counter(let center, let value):
            drawCounter(
                value,
                center: center,
                radius: max(12, annotation.lineWidth * 4),
                color: annotation.color,
                in: context,
                imageHeight: imageHeight
            )
        }
    }

    private static func drawArrow(
        from: CGPoint,
        to: CGPoint,
        lineWidth: CGFloat,
        in context: CGContext,
        imageHeight: Int
    ) {
        let start = contextPoint(from, imageHeight: imageHeight)
        let end = contextPoint(to, imageHeight: imageHeight)

        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let angle = atan2(end.y - start.y, end.x - start.x)
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

    private static func drawCounter(
        _ value: Int,
        center: CGPoint,
        radius: CGFloat,
        color: RGBAColor,
        in context: CGContext,
        imageHeight: Int
    ) {
        let centerPoint = contextPoint(center, imageHeight: imageHeight)
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
        base: CGImage,
        mosaic: CGImage?,
        in context: CGContext,
        imageHeight: Int
    ) {
        guard let mosaic, mosaic.width > 0, mosaic.height > 0 else { return }
        let scaleX = CGFloat(mosaic.width) / CGFloat(base.width)
        let scaleY = CGFloat(mosaic.height) / CGFloat(base.height)
        let source = CGRect(
            x: rect.minX * scaleX,
            y: rect.minY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: mosaic.width, height: mosaic.height))
        guard !source.isEmpty, let crop = mosaic.cropping(to: source) else { return }

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

    /// 图像像素矩形（原点左上）→ CGContext 矩形（原点左下）。
    private static func contextRect(_ rect: CGRect, imageHeight: Int) -> CGRect {
        CGRect(
            x: rect.minX,
            y: CGFloat(imageHeight) - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 图像像素点（原点左上）→ CGContext 点（原点左下）。
    private static func contextPoint(_ point: CGPoint, imageHeight: Int) -> CGPoint {
        CGPoint(x: point.x, y: CGFloat(imageHeight) - point.y)
    }
}
