import AppKit

/// 标注渲染 — 马赛克与模糊。
///
/// @author ixxxxoooo
extension AnnotationRenderer {
    static func drawMosaic(
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
    static func drawBlur(
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

    static func drawEraser(
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

    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func makeLine(_ string: String, font: CTFont, color: RGBAColor) -> CTLine {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor,
        ]
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)!
        return CTLineCreateWithAttributedString(attributed)
    }

}
