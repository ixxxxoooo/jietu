import AppKit

/// 遮罩画布 — 原地编辑的对象选中、控制点与命中判定。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    var selectedAnnotation: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    func updateAnnotation(_ id: UUID, _ transform: (Annotation) -> Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index] = transform(annotations[index])
    }

    /// 选中标注时把工具栏反向同步成该标注的当前参数。
    ///
    /// - Parameter updateTool: 是否连当前工具一起切换。**选中已有标注时传 `false`**：
    ///   用户明明选着「选择」工具去点标注，不该被自动换成那条标注的绘制工具——那样
    ///   "选择"就没了，下一次点击又会变成画新图形。只有刚画完一条新标注（工具本就是它）
    ///   才用默认的 `true` 顺带对齐一次。
    func syncToolbarToAnnotation(_ annotation: Annotation, updateTool: Bool = true) {
        guard let model = toolbarModel else { return }
        isSyncingToolbarToSelection = true
        defer { isSyncingToolbarToSelection = false }

        func select(_ tool: AnnotationTool) {
            if updateTool { model.tool = tool }
        }

        switch annotation.kind {
        case .blur(_, let radius):
            select(.blur)
            model.blurRadius = radius
        case .pixelate(_, let block):
            select(.pixelate)
            model.mosaicBlock = block
        case .rectangle:
            select(.rectangle)
            model.color = annotation.color
            model.lineWidth = annotation.lineWidth
            model.shapeFillMode = annotation.shapeFillMode
            model.rectCornerStyle = annotation.rectCornerStyle
        case .ellipse:
            select(.ellipse)
            model.color = annotation.color
            model.lineWidth = annotation.lineWidth
            model.shapeFillMode = annotation.shapeFillMode
        case .arrow:
            select(.arrow)
            model.color = annotation.color
            model.lineWidth = annotation.lineWidth
            model.arrowStyle = annotation.arrowStyle
        case .line:
            select(.line)
            model.color = annotation.color
            model.lineWidth = annotation.lineWidth
        case .pen:
            select(.pen)
            model.color = annotation.color
            model.lineWidth = annotation.lineWidth
        case .highlight:
            select(.highlight)
            model.highlightColor = annotation.color
            model.highlightLineWidth = annotation.lineWidth
        case .spotlight:
            select(.spotlight)
        case .text(_, _, let fontSize):
            select(.text)
            model.color = annotation.color
            model.fontSize = fontSize
            model.textHasStroke = annotation.textHasStroke
            model.textHasCallout = annotation.textHasCallout
        case .counter, .callout:
            select(.counter)
            model.color = annotation.color
            model.lineWidth = annotation.lineWidth
        case .eraser:
            break
        }
    }

    /// 选中态的控制点（crop 像素坐标）。
    func inlineHandles(for annotation: Annotation) -> [(ShapeHandle, CGPoint)] {
        var handles: [(ShapeHandle, CGPoint)] = []
        if abs(annotation.rotation) < 0.001 {
            switch annotation.kind {
            case .rectangle, .ellipse, .spotlight, .highlight, .pixelate, .pen, .text, .blur:
                handles.append(contentsOf: ShapeGeometry.resizeHandles(for: annotation))
            default:
                break
            }
        }
        switch annotation.kind {
        case .arrow(let from, let to, let control):
            handles.append((.arrowStart, from))
            handles.append((.arrowEnd, to))
            handles.append(
                (.arrowControl, control ?? CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2))
            )
        case .line(let from, let to, let control):
            handles.append((.lineStart, annotation.toWorld(from)))
            handles.append((.lineEnd, annotation.toWorld(to)))
            let defaultMid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            handles.append(
                (.lineControl, annotation.toWorld(control ?? defaultMid))
            )
        case .counter(let center, _, let leader):
            handles.append(
                (.counterLeader, leader ?? CGPoint(x: center.x + 48, y: center.y - 48))
            )
        default:
            break
        }
        if annotation.supportsRotation {
            handles.append((.rotate, ShapeGeometry.rotateHandle(for: annotation, distance: 28)))
        }
        return handles
    }

    func updateInlineSelectionLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let target = selectedAnnotation ?? (hoveredAnnotationID.flatMap { id in annotations.first { $0.id == id } })

        guard phase == .annotating, let target, inlineEditingTextID == nil else {
            inlineSelectionBorderLayer.isHidden = true
            inlineHandlesLayer.isHidden = true
            inlineSelectionBorderLayer.path = nil
            inlineHandlesLayer.path = nil
            return
        }

        if case .line = target.kind {
            inlineSelectionBorderLayer.isHidden = true
            inlineSelectionBorderLayer.path = nil
        } else {
            let corners = target.rotatedCorners().map { viewPoint($0) }
            let border = CGMutablePath()
            border.addLines(between: corners)
            border.closeSubpath()
            inlineSelectionBorderLayer.path = border
            inlineSelectionBorderLayer.isHidden = false
        }

        let path = CGMutablePath()
        let radius = Self.inlineHandleRadius
        for (_, point) in inlineHandles(for: target) {
            let center = viewPoint(point)
            path.addEllipse(
                in: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        }
        inlineHandlesLayer.path = path
        inlineHandlesLayer.isHidden = false
    }

    static let inlineHandleRadius: CGFloat = 4.5

    func inlineHitHandle(_ annotation: Annotation, at cropPoint: CGPoint) -> ShapeHandle? {
        // 文字框往往很小，通用容差会整个伸进框内、把「点文字改字」抢成缩放，故收紧一半。
        var tolerance = 11 * snapshot.effectiveScale
        if case .text = annotation.kind { tolerance = max(6, tolerance / 2) }
        var best: (ShapeHandle, CGFloat)?
        for (handle, point) in inlineHandles(for: annotation) {
            let distance = Annotation.distance(cropPoint, point)
            if distance <= tolerance, best == nil || distance < best!.1 {
                best = (handle, distance)
            }
        }
        return best?.0
    }

    func inlineAnnotation(at cropPoint: CGPoint) -> Annotation? {
        let tolerance = max(6, 8 * snapshot.effectiveScale)
        return annotations.last { $0.contains(cropPoint, tolerance: tolerance) }
    }

    /// 已选中对象的**编辑框**（带控制点的包围盒）是否包含某点（crop 像素坐标）。
    ///
    /// 编辑框画的就是 `rotatedCorners()` 那圈，所以先按对象自身的旋转把点转进本地坐标
    /// 再比 `localBounds`——旋转过的对象也能正确命中。`inlineAnnotation` 只认图形本身，
    /// 未填充的矩形 / 椭圆内部命中不到，靠这个才能"框内任意处都能拖"。
    func inlineBoxContains(_ annotation: Annotation, _ cropPoint: CGPoint) -> Bool {
        let local = annotation.toLocal(cropPoint)
        return annotation.localBounds.insetBy(dx: -6, dy: -6).contains(local)
    }

    /// 点是否落在「选中框的边」上（控制点由 `inlineHitHandle` 单独负责，别抢它的活）。
    ///
    /// 用来在框边显示小手光标：提示这里按着能拖动整个对象。内部空白不算边，
    /// 所以文字框内部照旧给 I 形光标（点进去改字）。
    func inlineBoxBorderContains(_ annotation: Annotation, _ cropPoint: CGPoint) -> Bool {
        let box = annotation.localBounds
        guard box.width > 0, box.height > 0 else { return false }
        let local = annotation.toLocal(cropPoint)
        let tolerance = max(6, 8 * snapshot.effectiveScale)
        return Annotation.distanceToRectBorder(local, rect: box) <= tolerance
    }

    func textOrigin(of annotation: Annotation) -> CGPoint {
        if case .text(let origin, _, _) = annotation.kind { return origin }
        return annotation.center
    }
}
