import AppKit

/// 遮罩画布 — 原地编辑的坐标换算与草稿标注生成。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    /// 屏幕上**底图**占的矩形：恢复图片模式是底图自己的 frame，普通区域截图就是当前选区。
    ///
    /// 标注的坐标换算一律以它为准。裁剪框（或缩放）改动的是**选区**——「要保留哪一块」的框，
    /// 底图并没有跟着变形；拿选区当基准的话，一拖裁剪框标注就会被压扁、点也点不准。
    var baseFrameInView: CGRect? {
        restoredImageFrame ?? selection
    }

    /// 底图的像素图（标注层 / 实况文本的渲染源），与 `baseFrameInView` 成对使用。
    var baseImageInView: CGImage? {
        restoredBaseImage ?? cropImage
    }

    /// 视图坐标（原点左下）→ 底图像素坐标（原点左上）。
    func annotationPoint(from point: CGPoint) -> CGPoint {
        guard let frame = baseFrameInView, frame.width > 0, frame.height > 0 else { return .zero }
        let scaleX: CGFloat
        let scaleY: CGFloat
        if let base = baseImageInView {
            scaleX = CGFloat(base.width) / frame.width
            scaleY = CGFloat(base.height) / frame.height
        } else {
            scaleX = snapshot.effectiveScale
            scaleY = snapshot.effectiveScale
        }
        return CGPoint(
            x: (point.x - frame.minX) * scaleX,
            y: (frame.maxY - point.y) * scaleY
        )
    }

    /// 底图像素坐标 → 视图坐标（原点左下）。
    func viewPoint(fromAnnotation point: CGPoint) -> CGPoint {
        guard let frame = baseFrameInView, frame.width > 0, frame.height > 0 else { return .zero }
        let scaleX: CGFloat
        let scaleY: CGFloat
        if let base = baseImageInView {
            scaleX = CGFloat(base.width) / frame.width
            scaleY = CGFloat(base.height) / frame.height
        } else {
            scaleX = snapshot.effectiveScale
            scaleY = snapshot.effectiveScale
        }
        return CGPoint(x: frame.minX + point.x / scaleX, y: frame.maxY - point.y / scaleY)
    }

    func viewPoint(_ point: CGPoint) -> CGPoint {
        viewPoint(fromAnnotation: point)
    }

    func makeInlineDraft(start: CGPoint, current: CGPoint) -> Annotation? {
        guard let model = toolbarModel, let tool = model.tool else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
        switch tool {
        case .rectangle:
            return Annotation(
                kind: .rectangle(rect),
                color: model.color,
                lineWidth: model.lineWidth,
                shapeFillMode: model.shapeFillMode,
                rectCornerStyle: model.rectCornerStyle
            )
        case .ellipse:
            return Annotation(
                kind: .ellipse(rect),
                color: model.color,
                lineWidth: model.lineWidth,
                shapeFillMode: model.shapeFillMode
            )
        case .highlight:
            // 荧光笔不是「拉一个框涂色」，是拿笔刷沿手指涂一条（参考 capcap 的高亮笔）。
            return Annotation(
                kind: .highlight(points: [start, current]),
                color: model.highlightColor,
                lineWidth: model.highlightLineWidth
            )
        case .spotlight:
            return Annotation(kind: .spotlight(rect), color: model.color, lineWidth: model.lineWidth)
        case .pixelate:
            return Annotation(kind: .pixelate(rect, block: model.mosaicBlock), color: model.color, lineWidth: model.lineWidth)
        case .blur:
            return Annotation(kind: .blur(rect, radius: model.blurRadius), color: model.color, lineWidth: model.lineWidth)
        case .arrow:
            return Annotation(
                kind: .arrow(from: start, to: current, control: nil),
                color: model.color,
                lineWidth: model.lineWidth,
                arrowStyle: model.arrowStyle
            )
        case .line:
            return Annotation(kind: .line(from: start, to: current), color: model.color, lineWidth: model.lineWidth)
        case .pen:
            return Annotation(kind: .pen(points: [start, current]), color: model.color, lineWidth: model.lineWidth)
        case .counter:
            return Annotation(
                kind: .counter(center: start, value: inlineCounterValue, leader: nil),
                color: model.color,
                lineWidth: model.lineWidth
            )
        // 裁剪只在标注编辑器窗口里提供，原地编辑不参与。
        case .text, .select, .eraser, .crop: return nil
        }
    }

    func isValidInlineDraft(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle(let rect), .ellipse(let rect), .spotlight(let rect), .pixelate(let rect, _),
            .blur(let rect, _):
            return rect.width >= 3 && rect.height >= 3
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 3
        case .line(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 3
        case .counter, .callout, .pen, .highlight, .text, .eraser:
            return true
        }
    }
}
