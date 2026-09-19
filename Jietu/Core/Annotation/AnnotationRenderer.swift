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

    static func draw(
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

    // MARK: - Coordinate conversion

    static func contextRect(_ rect: CGRect, imageHeight: Int) -> CGRect {
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

    static func contextPoint(_ point: CGPoint, imageHeight: Int) -> CGPoint {
        CGPoint(x: point.x, y: CGFloat(imageHeight) - point.y)
    }
}
