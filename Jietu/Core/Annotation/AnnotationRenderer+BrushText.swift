import AppKit

/// 标注渲染 — 画笔、高亮笔、聚光灯、文字、序号。
///
/// @author ixxxxoooo
extension AnnotationRenderer {
    static func drawPen(_ points: [CGPoint], in context: CGContext, imageHeight: Int) {
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
    static func drawHighlight(
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
    static func smoothedPolyline(_ raw: [CGPoint]) -> CGPath {
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
    static func drawSpotlight(_ rects: [CGRect], in context: CGContext, imageHeight: Int) {
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
    static func spotlightMask(width: Int, height: Int, holes: [CGRect]) -> CGImage? {
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

    static func drawText(
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

    static func drawCallout(
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
    static func drawCenteredText(
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

    static func drawCounter(
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

}
