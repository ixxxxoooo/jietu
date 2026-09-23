import AppKit
import SwiftUI

/// 遮罩画布 — 原地标注编辑（工具、裁剪、compose、文本框）。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    /// 选区定下来后进入原地标注：工具栏出现在选框下方，直接在冻结画面上标注。
    func enterAnnotating() {
        guard inlineMode, let selection, selection.width > 1, selection.height > 1 else { return }
        phase = .annotating
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        eraserStrokes.removeAll()
        annotationDraft = nil
        selectedID = nil
        inlineEditingTextID = nil
        interaction = .settled
        onInlineEditingChanged?(true)

        // 选区绿框与控制点**继续留在画面上**：工具栏弹出后，拖着边缘还能改区域。
        updateSelectionLayers()
        windowHighlightLayer.isHidden = true
        crosshairLayer.path = nil

        preparePreviewBase()
        updateLiveTextOverlay()
        // 进入时就只弹工具栏，不显示任何标注层，避免画面「跳」一下。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        annotationLayer.contents = nil
        annotationLayer.isHidden = true
        CATransaction.commit()
        showToolbar()
        window?.invalidateCursorRects(for: self)
        updateCursor(at: cursorPoint ?? .zero)
    }

    func exitAnnotating() {
        hideToolbar()
        liveTextHost?.removeFromSuperview()
        liveTextHost = nil
        cropImage = nil
        restoredBaseImage = nil
        restoredImageFrame = nil
        restoredContainerLayer.isHidden = true
        restoredImageLayer.contents = nil
        textField?.removeFromSuperview()
        textField = nil
        annotations.removeAll()
        eraserStrokes.removeAll()
        annotationDraft = nil
        selectedID = nil
        inlineEditingTextID = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        annotationLayer.contents = nil
        annotationLayer.isHidden = true
        inlineSelectionBorderLayer.isHidden = true
        inlineHandlesLayer.isHidden = true
        CATransaction.commit()
        phase = .selecting
        onInlineEditingChanged?(false)
        updateAllLayers()
        window?.invalidateCursorRects(for: self)
        updateCursor(at: cursorPoint ?? .zero)
    }

    /// 标注态里拖动选区边缘：改选区的同时，把标注 / 橡皮笔迹按**新原点**平移，
    /// 让它们继续钉在画面的同一处（否则会跟着框一起跑）。
    func applyRegionResize(from previous: CGRect, to updated: CGRect) {
        guard updated != previous else { return }

        // 恢复图片模式下，底图是固定静态像素图，拖动只调整裁剪选区，标注保持相对底图不变
        if restoredBaseImage != nil {
            selection = updated
            updateRestoredImageLayer()
            updateDimPath()
            updateSelectionLayers()
            updateAnnotationLayer()
            updateInlineSelectionLayers()
            layoutToolbars()
            return
        }

        // 选区原点在屏幕坐标里的位移 → 图像坐标里的反向位移：
        // 左 / 上边缘往外扩，同一画面内容在图像里的坐标就变大。
        let delta = SelectionGeometry.imageDelta(
            from: previous,
            to: updated,
            scale: snapshot.effectiveScale
        )
        if delta != .zero {
            annotations = annotations.map { $0.translated(by: delta) }
            eraserStrokes = eraserStrokes.map { stroke in
                EraserStroke(
                    points: stroke.points.map {
                        CGPoint(x: $0.x + delta.width, y: $0.y + delta.height)
                    },
                    radius: stroke.radius
                )
            }
            if let draft = annotationDraft {
                annotationDraft = draft.translated(by: delta)
            }
        }

        selection = updated
        // 底图换了一块，预览底图 / 标注层 / 选区视觉 / 工具栏位置都要跟着更新。
        preparePreviewBase()
        updateDimPath()
        updateSelectionLayers()
        updateAnnotationLayer()
        updateInlineSelectionLayers()
        layoutToolbars()
    }

    // MARK: - Crop actions

    /// 裁剪工具下的按下：双击直接完成裁剪；抓到裁剪框边缘就微调；**在图上任意位置按下
    /// （包括正中间）则拖出一个新的裁剪框**——这正是裁剪与「拖外面那个选框」的区别。
    ///
    /// - Returns: `true` 表示这次按下归裁剪管，调用方不必再走标注那条路。
    func cropMouseDown(_ point: CGPoint, clickCount: Int) -> Bool {
        guard toolbarModel?.tool == .crop, let bounds = cropBaseFrame else { return false }
        if clickCount >= 2 {
            applyCrop()
            return true
        }
        if cropSessionFrame == nil {
            // 这一轮裁剪的「那张图」先定下来：之后不管框怎么缩，图的边界都留在原位。
            cropSessionFrame = bounds
        }
        if let selection,
            let handle = SelectionGeometry.handle(
                at: point,
                in: selection,
                tolerance: Theme.selectionHandleHitTolerance
            )
        {
            interaction = .resizing(handle: handle, original: selection)
            return true
        }
        // 图外（压暗区 / 工具栏）按下不归裁剪管。
        guard bounds.contains(point) else { return false }
        interaction = .pressing(anchor: point)
        return true
    }

    /// 裁剪框拖拽中：从按下点拉出一个矩形，范围锁在当前底图之内。
    ///
    /// - Returns: `true` 表示这一拖归裁剪管。
    func cropMouseDragged(_ point: CGPoint, lockAspect: Bool) -> Bool {
        guard toolbarModel?.tool == .crop, let bounds = cropBaseFrame else { return false }
        if case .pressing(let anchor) = interaction {
            // 没超过拖拽阈值就什么都不做：单击不该毁掉已有的裁剪框。
            guard hypot(point.x - anchor.x, point.y - anchor.y) >= Theme.dragActivationDistance else {
                return true
            }
            interaction = .selecting(anchor: anchor)
        }
        guard case .selecting(let anchor) = interaction else { return false }
        cursorPoint = point
        let updated = SelectionGeometry.selectionRect(
            from: anchor,
            to: point,
            clampTo: bounds,
            square: lockAspect
        )
        applyRegionResize(from: selection ?? updated, to: updated)
        return true
    }

    /// 裁剪框拖拽收手：框留着等确认（↵ / 双击 / 「完成裁剪」）；太小的框当作没拖，退回原范围。
    ///
    /// - Returns: `true` 表示这一次收手归裁剪管。
    func cropMouseUp() -> Bool {
        switch interaction {
        case .pressing:
            // 只是点了一下：保持原裁剪框。
            interaction = .settled
            return true
        case .selecting:
            interaction = .settled
            if let bounds = cropSessionFrame, let selection,
                selection.width < Self.minimumCropSide || selection.height < Self.minimumCropSide
            {
                // 一拖就松的小框：当作单击误触，把范围还回去（顺带把标注的位移还原）。
                applyRegionResize(from: selection, to: bounds)
            }
            return true
        default:
            return false
        }
    }

    /// 裁剪框的可选范围：恢复图片模式是当前底图，普通区域截图是当前那块选区。
    var cropBaseFrame: CGRect? {
        restoredImageFrame ?? selection
    }

    /// 这一轮裁剪里「正在裁的那张图」占的屏幕矩形（第一次按下时定下，直到确认 / 取消）。
    ///
    /// 裁剪框只标记「要保留哪一块」：图的边界始终留在原位、图本身也不再被压暗层遮住，
    /// 否则框一缩小，框外露出底下的冻结屏幕，就分不清图到哪儿为止了。
    var cropFrame: CGRect? {
        guard toolbarModel?.tool == .crop else { return nil }
        return cropSessionFrame ?? cropBaseFrame
    }

    /// 还悬着一个「框好了但没落实」的裁剪（框确实比图小，落实下去会真的改变图）。
    var hasPendingCrop: Bool {
        guard let selection, let frame = cropFrame else { return false }
        return selection != frame
    }

    func applyCrop() {
        // 框和整张图一样大 = 没裁东西，不占撤销位。
        if hasPendingCrop, let initial = cropInitialState {
            undoStack.append(initial)
            redoStack.removeAll()
        }
        cropInitialState = nil
        cropSessionFrame = nil
        performCropExecution()
        toolbarModel?.tool = nil
        updateRestoredImageLayer()
        updateSelectionLayers()
        updateAnnotationLayer()
        updateDimPath()
        layoutToolbars()
    }

    func applyDirectResizeCrop() {
        performCropExecution()
        updateRestoredImageLayer()
        updateSelectionLayers()
        updateAnnotationLayer()
        updateDimPath()
        layoutToolbars()
    }

    func performCropExecution() {
        guard let selection else { return }
        if let restored = restoredBaseImage, let baseFrame = restoredImageFrame {
            let cropRect = selection.intersection(baseFrame)
            guard cropRect.width >= Self.minimumCropSide, cropRect.height >= Self.minimumCropSide else {
                self.selection = baseFrame
                return
            }
            if cropRect != baseFrame {
                let scaleX = CGFloat(restored.width) / baseFrame.width
                let scaleY = CGFloat(restored.height) / baseFrame.height
                let pixelX = (cropRect.minX - baseFrame.minX) * scaleX
                let pixelY = (baseFrame.maxY - cropRect.maxY) * scaleY
                let pixelW = cropRect.width * scaleX
                let pixelH = cropRect.height * scaleY
                let pixelRect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH).integral
                if let result = CropOperation.crop(restored, to: pixelRect) {
                    let delta = CropOperation.offset(for: result.rect)
                    annotations = CropOperation.shifted(annotations, by: delta)
                    eraserStrokes = CropOperation.shifted(eraserStrokes, by: delta)
                    restoredBaseImage = result.image
                    cropImage = result.image
                    self.selection = cropRect
                    self.restoredImageFrame = cropRect
                }
            }
            return
        }

        // 普通截图的原地裁剪
        preparePreviewBase()
    }

    func cancelCrop() {
        if let initial = cropInitialState {
            apply(initial)
        } else if let restoredBaseImage, let baseFrame = restoredImageFrame {
            selection = baseFrame
        }
        toolbarModel?.tool = nil
        cropInitialState = nil
        cropSessionFrame = nil
        updateRestoredImageLayer()
        updateSelectionLayers()
        updateAnnotationLayer()
        updateDimPath()
        layoutToolbars()
    }

    func cancelInline() {
        exitAnnotating()
        selection = nil
        interaction = .idle
        updateAllLayers()
    }

    /// 当前「已烘焙标注」的成图（用于下载 / 钉图）。
    func currentAnnotatedImage() -> CGImage? {
        applyPendingCropIfNeeded()
        commitPendingInlineText()
        guard let selection else { return nil }
        let base: CGImage
        if let restoredBaseImage {
            base = restoredBaseImage
        } else if let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) {
            base = crop
        } else {
            return nil
        }
        return compose(base: base, annotations: annotations, strokes: eraserStrokes) ?? base
    }

    func confirmInline() {
        applyPendingCropIfNeeded()
        guard let selection else {
            cancelInline()
            return
        }
        let base: CGImage
        if let restoredBaseImage {
            base = restoredBaseImage
        } else if let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) {
            base = crop
        } else {
            cancelInline()
            return
        }
        commitPendingInlineText()
        let final = compose(base: base, annotations: annotations, strokes: eraserStrokes) ?? base
        let rect = selection
        exitAnnotating()
        onCommitAnnotated?(final, rect)
    }

    /// 交出去之前先把「框好了但还没落实」的裁剪落实掉。
    ///
    /// 裁剪是「先框、后确认」：用户框完直接点主工具栏的 ✓（或保存 / 钉图）时，
    /// 若不管这个框，交出去的还是没裁过的原图——看到的就是「裁完怎么还是原来那张」。
    func applyPendingCropIfNeeded() {
        guard hasPendingCrop else { return }
        applyCrop()
    }

    /// 记住选区对应的原图。标注层就直接按它的原始分辨率渲染（见 `updateAnnotationLayer`）。
    func preparePreviewBase() {
        if let restoredBaseImage {
            cropImage = restoredBaseImage
            updateRestoredImageLayer()
            return
        }
        guard let selection, let crop = CaptureOutput.crop(snapshot, toLocalRect: selection) else {
            cropImage = nil
            return
        }
        cropImage = crop
    }

    func updateAnnotationLayer() {
        toolbarModel?.canUndo = !undoStack.isEmpty
        toolbarModel?.canRedo = !redoStack.isEmpty

        // 草稿要「有实际尺寸」才画；单击产生的零尺寸草稿不显示，避免闪一下。
        var list = annotations
        if let editingID = inlineEditingTextID {
            list.removeAll { $0.id == editingID }
        }
        if let annotationDraft, isMeaningfulDraft(annotationDraft) {
            list.append(annotationDraft)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard let base = baseImageInView, let frame = baseFrameInView, !list.isEmpty else {
            annotationLayer.contents = nil
            annotationLayer.isHidden = true
            CATransaction.commit()
            return
        }
        // 标注层按**原图分辨率**渲染一张透明底的「标注图层」，叠在冻结图之上：
        // 1:1 落在屏幕上，线 / 箭头不会有缩放锯齿；又因为不用每帧重画底图，
        // 比之前「缩到 1600 再画底图」还快（实测 2560 宽的选区 0.5ms vs 1.7ms）。
        let image = compose(
            base: base,
            annotations: list,
            strokes: eraserStrokes,
            drawsBase: false
        )
        // 贴**底图**的 frame（不是选区）：裁剪 / 缩放时选区会变，底图不变。
        annotationLayer.frame = frame
        annotationLayer.contents = image
        annotationLayer.isHidden = false
        CATransaction.commit()
    }

    /// 依次绘制标注（含按先后顺序擦除恢复底图的橡皮）。
    ///
    /// `drawsBase = false` 时输出透明底的标注图层（供原地预览叠在冻结图上）。
    func compose(
        base: CGImage,
        annotations: [Annotation],
        strokes: [EraserStroke],
        drawsBase: Bool = true
    ) -> CGImage? {
        AnnotationRenderer.render(
            base: base,
            annotations: annotations,
            eraserStrokes: strokes,
            drawsBase: drawsBase
        )
    }

    /// 草稿是否已经「成形」（用于避免单击时的零尺寸闪烁）。
    func isMeaningfulDraft(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle(let rect), .ellipse(let rect), .spotlight(let rect), .pixelate(let rect, _),
            .blur(let rect, _):
            return rect.width >= 1.5 || rect.height >= 1.5
        case .arrow(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 2
        case .line(let from, let to, _):
            return hypot(to.x - from.x, to.y - from.y) >= 2
        case .pen(let points), .highlight(let points):
            return points.count >= 2
        case .counter, .callout, .eraser:
            return true
        case .text:
            return false
        }
    }

    func pushUndo() {
        undoStack.append(
            Snapshot(
                annotations: annotations,
                strokes: eraserStrokes,
                selection: selection,
                restoredBaseImage: restoredBaseImage,
                restoredImageFrame: restoredImageFrame
            )
        )
        redoStack.removeAll()
    }

    func inlineUndo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(
            Snapshot(
                annotations: annotations,
                strokes: eraserStrokes,
                selection: selection,
                restoredBaseImage: restoredBaseImage,
                restoredImageFrame: restoredImageFrame
            )
        )
        apply(previous)
    }

    func inlineRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(
            Snapshot(
                annotations: annotations,
                strokes: eraserStrokes,
                selection: selection,
                restoredBaseImage: restoredBaseImage,
                restoredImageFrame: restoredImageFrame
            )
        )
        apply(next)
    }

    func apply(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        eraserStrokes = snapshot.strokes

        let imageChanged = snapshot.restoredBaseImage !== restoredBaseImage
        restoredBaseImage = snapshot.restoredBaseImage
        restoredImageFrame = snapshot.restoredImageFrame

        let selectionChanged = snapshot.selection != selection || imageChanged
        selection = snapshot.selection
        if selectionChanged {
            preparePreviewBase()
            updateDimPath()
            updateSelectionLayers()
            updateRestoredImageLayer()
            layoutToolbars()
        }

        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }

    // MARK: Inline selection / editing

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
        let tolerance = 11 * snapshot.effectiveScale
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

    func textOrigin(of annotation: Annotation) -> CGPoint {
        if case .text(let origin, _, _) = annotation.kind { return origin }
        return annotation.center
    }

    // MARK: Inline toolbar

    func showToolbar() {
        let seed = annotationDefaults.sanitized
        let model = InlineToolbarModel()
        model.tool = nil
        model.color = seed.color
        model.lineWidth = seed.lineWidth
        model.highlightColor = seed.highlightColor
        model.highlightLineWidth = seed.highlightLineWidth
        model.fontSize = seed.fontSize
        model.eraserSize = seed.eraserSize
        model.mosaicBlock = seed.mosaicBlock
        model.blurRadius = seed.blurRadius
        model.arrowStyle = seed.arrowStyle
        model.shapeFillMode = seed.shapeFillMode
        model.rectCornerStyle = seed.rectCornerStyle
        model.textHasStroke = seed.textHasStroke
        model.textHasCallout = seed.textHasCallout
        model.editorShortcuts = editorShortcuts
        model.isRestoredImage = (restoredBaseImage != nil)
        model.allowsCrop = allowsCrop
        model.onConfirm = { [weak self] in self?.confirmInline() }
        model.onCancel = { [weak self] in self?.onCancel?() }
        model.onUndo = { [weak self] in self?.inlineUndo() }
        model.onRedo = { [weak self] in self?.inlineRedo() }
        model.onApplyCrop = { [weak self] in self?.applyCrop() }
        model.onTextStyleChange = { [weak self] effect in
            self?.applyTextStyleToSelection(effect)
        }
        model.onCancelCrop = { [weak self] in self?.cancelCrop() }
        model.onSave = { [weak self] in
            guard let self, let image = self.currentAnnotatedImage() else { return }
            self.onSaveImage?(image)
        }
        model.onPin = { [weak self] in
            guard let self, let image = self.currentAnnotatedImage() else { return }
            self.onPinImage?(image, self.selection ?? .zero)
        }
        model.onScrollCapture = { [weak self] mode in self?.beginScrollCapture(mode: mode) }
        // 工具栏的「录屏」：和「框好一块区域去录屏」走的是同一条交接（`onRecordRegionPicked`），
        // 区别只是这回选区是用户在就地工具栏前调好的。
        model.onRecord = { [weak self] in
            guard let self, let selection = self.selection else { return }
            self.onRecordRegionPicked?(selection)
        }
        model.onSliderEditStart = { [weak self] in
            guard let self, self.selectedID != nil else { return }
            self.pushUndo()
        }
        model.onBlurRadiusChange = { [weak self] radius in
            guard let self, !self.isSyncingToolbarToSelection,
                let selectedID = self.selectedID,
                let index = self.annotations.firstIndex(where: { $0.id == selectedID }),
                case .blur(let rect, let oldRadius) = self.annotations[index].kind,
                abs(oldRadius - radius) > 0.01
            else { return }
            self.annotations[index] = self.annotations[index].withBlurRadius(radius)
            self.updateAnnotationLayer()
        }
        model.onMosaicBlockChange = { [weak self] block in
            guard let self, !self.isSyncingToolbarToSelection,
                let selectedID = self.selectedID,
                let index = self.annotations.firstIndex(where: { $0.id == selectedID }),
                case .pixelate(let rect, let oldBlock) = self.annotations[index].kind,
                abs(oldBlock - block) > 0.01
            else { return }
            self.annotations[index] = self.annotations[index].withPixelateBlock(block)
            self.updateAnnotationLayer()
        }
        model.onColorChange = { [weak self] color in
            guard let self, !self.isSyncingToolbarToSelection,
                let selectedID = self.selectedID,
                let index = self.annotations.firstIndex(where: { $0.id == selectedID })
            else { return }
            switch self.annotations[index].kind {
            case .blur, .pixelate, .spotlight, .eraser: return
            default: break
            }
            guard self.annotations[index].color != color else { return }
            self.pushUndo()
            self.annotations[index] = self.annotations[index].withColor(color)
            self.updateAnnotationLayer()
            self.updateInlineSelectionLayers()
        }
        model.onLineWidthChange = { [weak self] width in
            guard let self, !self.isSyncingToolbarToSelection,
                let selectedID = self.selectedID,
                let index = self.annotations.firstIndex(where: { $0.id == selectedID })
            else { return }
            switch self.annotations[index].kind {
            case .blur, .pixelate, .spotlight, .eraser, .text: return
            default: break
            }
            guard abs(self.annotations[index].lineWidth - width) > 0.01 else { return }
            self.annotations[index] = self.annotations[index].withLineWidth(width)
            self.updateAnnotationLayer()
            self.updateInlineSelectionLayers()
        }
        model.onShapeFillModeChange = { [weak self] mode in
            guard let self, !self.isSyncingToolbarToSelection,
                let selectedID = self.selectedID,
                let index = self.annotations.firstIndex(where: { $0.id == selectedID })
            else { return }
            switch self.annotations[index].kind {
            case .rectangle, .ellipse:
                guard self.annotations[index].shapeFillMode != mode else { return }
                self.pushUndo()
                self.annotations[index] = self.annotations[index].withShapeFillMode(mode)
                self.updateAnnotationLayer()
                self.updateInlineSelectionLayers()
            default: break
            }
        }
        model.onRectCornerStyleChange = { [weak self] style in
            guard let self, !self.isSyncingToolbarToSelection,
                let selectedID = self.selectedID,
                let index = self.annotations.firstIndex(where: { $0.id == selectedID }),
                case .rectangle = self.annotations[index].kind,
                self.annotations[index].rectCornerStyle != style
            else { return }
            self.pushUndo()
            self.annotations[index] = self.annotations[index].withRectCornerStyle(style)
            self.updateAnnotationLayer()
            self.updateInlineSelectionLayers()
        }
        model.onArrowStyleChange = { [weak self] style in
            guard let self, !self.isSyncingToolbarToSelection,
                let selectedID = self.selectedID,
                let index = self.annotations.firstIndex(where: { $0.id == selectedID }),
                case .arrow = self.annotations[index].kind,
                self.annotations[index].arrowStyle != style
            else { return }
            self.pushUndo()
            self.annotations[index] = self.annotations[index].withArrowStyle(style)
            self.updateAnnotationLayer()
            self.updateInlineSelectionLayers()
        }
        model.onFontSizeChange = { [weak self] size in
            guard let self, !self.isSyncingToolbarToSelection,
                let selectedID = self.selectedID,
                let index = self.annotations.firstIndex(where: { $0.id == selectedID }),
                case .text = self.annotations[index].kind
            else { return }
            self.annotations[index] = self.annotations[index].withFontSize(size)
            self.updateAnnotationLayer()
            self.updateInlineSelectionLayers()
        }
        toolbarModel = model

        // 主工具栏：固定尺寸，永不重算 → 展开选项时也不闪烁。
        let main = NSHostingView(rootView: InlineMainToolbar(model: model))
        main.translatesAutoresizingMaskIntoConstraints = true
        main.layer?.masksToBounds = false
        addSubview(main)
        mainToolbarHost = main

        // 二级菜单：持久宿主，只靠 SwiftUI 内部响应驱动，避免拖拽滑块/调色时宿主反复重建闪烁
        let options = NSHostingView(rootView: InlineOptionsToolbar(model: model))
        options.translatesAutoresizingMaskIntoConstraints = true
        options.layer?.masksToBounds = false
        options.isHidden = !model.isSubToolbarVisible
        addSubview(options)
        optionsToolbarHost = options

        layoutToolbars()

        // 监听工具/参数变化以更新选项条与存档。
        observeOptions(model)
        observeDefaults(model)
    }

    /// 工具 / 颜色 / 参数变化时回报，由外部落盘（下次截图沿用）。
    func observeDefaults(_ model: InlineToolbarModel) {
        withObservationTracking {
            _ = model.tool
            _ = model.color
            _ = model.lineWidth
            _ = model.highlightColor
            _ = model.highlightLineWidth
            _ = model.fontSize
            _ = model.eraserSize
            _ = model.mosaicBlock
            _ = model.blurRadius
            _ = model.arrowStyle
            _ = model.shapeFillMode
            _ = model.rectCornerStyle
            _ = model.textHasStroke
            _ = model.textHasCallout
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.toolbarModel === model else { return }
                self.onAnnotationDefaultsChange?(
                    AnnotationDefaults(
                        tool: model.tool ?? self.annotationDefaults.tool,
                        color: model.color,
                        lineWidth: model.lineWidth,
                        highlightColor: model.highlightColor,
                        highlightLineWidth: model.highlightLineWidth,
                        fontSize: model.fontSize,
                        mosaicBlock: model.mosaicBlock,
                        blurRadius: model.blurRadius,
                        eraserSize: model.eraserSize,
                        arrowStyle: model.arrowStyle,
                        shapeFillMode: model.shapeFillMode,
                        rectCornerStyle: model.rectCornerStyle,
                        textHasStroke: model.textHasStroke,
                        textHasCallout: model.textHasCallout
                    )
                )
                self.observeDefaults(model)
            }
        }
    }

    /// 就地编辑工具栏里选了「手动 / 自动滚动」：把当前选区交给外面开跑滚动长图。
    ///
    /// 这里只做「收起自己的选项条 + 上报」：真正的会话要建控制条与实时预览、还要把遮罩
    /// 换成取景框（鼠标穿透），那是 AppDelegate 那一层的事。
    func beginScrollCapture(mode: ScrollingCaptureSession.Mode) {
        guard let selection else { return }
        toolbarModel?.showScroll = false
        onScrollCapture?(mode, selection)
    }

    #if DEBUG
    /// 自检用：等价于点一下工具栏的「滚动截图」（只展开选项，不真的开跑）。
    @discardableResult
    func debugOpenScrollOptions() -> Bool {
        guard toolbarModel != nil, selection != nil else { return false }
        toolbarModel?.showScroll = true
        return true
    }

    /// 自检用：等价于点一下工具栏的「录屏」。
    @discardableResult
    func debugTriggerRecord() -> Bool {
        guard toolbarModel != nil, selection != nil else { return false }
        onRecordRegionPicked?(selection!)
        return true
    }

    /// 自检用：等价于点一下工具栏的「滚动截图」→ 选某个模式。
    @discardableResult
    func debugTriggerScrollCapture(_ mode: ScrollingCaptureSession.Mode) -> Bool {
        guard toolbarModel != nil, selection != nil else { return false }
        toolbarModel?.showScroll = true
        beginScrollCapture(mode: mode)
        return true
    }
    #endif

    func hideToolbar() {
        mainToolbarHost?.removeFromSuperview()
        mainToolbarHost = nil
        optionsToolbarHost?.removeFromSuperview()
        optionsToolbarHost = nil
        toolbarModel = nil
    }

    /// 工具/参数/子工具栏开关变化时重新排版选项条。
    func observeOptions(_ model: InlineToolbarModel) {
        withObservationTracking {
            _ = model.isSubToolbarVisible
            _ = model.tool
            _ = model.showScroll
            _ = model.isLiveTextActive
            if self.textField != nil {
                _ = model.fontSize
                _ = model.color
                _ = model.textHasStroke
                _ = model.textHasCallout
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if let field = self.textField {
                    self.applyInlineTextStyle(field, model: model)
                    self.fitInlineTextField()
                }

                if model.tool == .crop && self.cropInitialState == nil {
                    self.cropInitialState = Snapshot(
                        annotations: self.annotations,
                        strokes: self.eraserStrokes,
                        selection: self.selection,
                        restoredBaseImage: self.restoredBaseImage,
                        restoredImageFrame: self.restoredImageFrame
                    )
                } else if model.tool != .crop {
                    self.cropInitialState = nil
                    self.cropSessionFrame = nil
                }
                // 进出裁剪都要重画：裁剪时压暗层挖的是整张图、还要给底图画外框（见 `updateCropFrameBorder`）。
                self.updateDimPath()
                self.updateSelectionLayers()
                self.optionsToolbarHost?.isHidden = !model.isSubToolbarVisible
                self.updateLiveTextOverlay()
                self.layoutToolbars()
                if self.toolbarModel === model {
                    self.observeOptions(model)
                }
            }
        }
    }

    /// 用户点了文字二级菜单里的「描边 / 标注」：把这一项**当场**刷到选中的那条文字上。
    ///
    /// 只由那个开关的回调触发（`onTextStyleChange`），**不能**挂在工具栏的通用观察上——
    /// 否则选中一条文字之后，换个工具 / 调个颜色都会拿工具栏当前值去覆盖它，把已有样式改坏。
    /// 也只动被点的那一项：点「描边」不该顺手把这条文字上的「标注」也改掉。
    /// 正在输入文字时走的是文本框那条路（`applyInlineTextStyle`），这里只管「没在输入、但选中了一条文字」。
    func applyTextStyleToSelection(_ effect: InlineToolbarModel.TextEffect) {
        guard textField == nil, let model = toolbarModel, let selectedID,
            let index = annotations.firstIndex(where: { $0.id == selectedID }),
            case .text = annotations[index].kind
        else { return }
        let updated: Annotation
        switch effect {
        case .stroke: updated = annotations[index].withTextStroke(model.textHasStroke)
        case .callout: updated = annotations[index].withTextCallout(model.textHasCallout)
        }
        guard updated != annotations[index] else { return }
        // 开关是离散的（不像滑块会连着刷），一次切换算一步撤销。
        pushUndo()
        annotations[index] = updated
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }

    /// 实况文本：选中「选择」工具时铺一层可拖选复制文字的覆盖层。
    func updateLiveTextOverlay() {
        let wantsLiveText = (toolbarModel?.isLiveTextActive ?? false) && cropImage != nil && selection != nil
        if wantsLiveText {
            if liveTextHost == nil, let image = baseImageInView {
                let host = NSHostingView(rootView: LiveTextOverlay(image: image))
                host.translatesAutoresizingMaskIntoConstraints = true
                addSubview(host)
                liveTextHost = host
            }
            if let host = liveTextHost, let frame = baseFrameInView {
                // 覆盖层是**底图**的一片，跟着底图的 frame 走（与标注层同一套基准）。
                host.frame = frame
            }
        } else {
            liveTextHost?.removeFromSuperview()
            liveTextHost = nil
        }
    }

    func rebuildOptionsToolbar() {
        optionsToolbarHost?.isHidden = !(toolbarModel?.isSubToolbarVisible ?? false)
        layoutToolbars()
    }

    /// 摆工具栏，优先级 **下 → 上 → 右 → 左**：
    /// 先横排贴选区下面（最顺手）；下面放不下就翻到选区上方**横排**；
    /// 上下都没位置才竖排停到右侧，右边也不行再退到左侧；四处都塞不下就夹进画布（别把工具栏弄丢）。
    func layoutToolbars() {
        guard let selection, let main = mainToolbarHost else { return }
        let inset: CGFloat = 8
        let gap: CGFloat = 10

        // 1. 下面。
        let horizontalSize = measureMainToolbar(vertical: false)
        if selection.minY - gap - horizontalSize.height >= bounds.minY + inset {
            placeHorizontal(main, size: horizontalSize, below: selection, inset: inset, gap: gap)
            layoutOptions(beside: main.frame, side: nil, inset: inset, gap: gap)
            return
        }

        // 2. 上面。（以前这里是最后兜底，导致「下面没位置」就直接竖排了——上面明明空着。）
        if selection.maxY + gap + horizontalSize.height <= bounds.maxY - inset {
            placeHorizontal(main, size: horizontalSize, below: selection, inset: inset, gap: gap, above: true)
            layoutOptions(beside: main.frame, side: nil, inset: inset, gap: gap, above: true)
            return
        }

        // 3. 右 → 左（竖排）。
        let verticalSize = measureMainToolbar(vertical: true)
        if let side = verticalDockSide(for: selection, mainSize: verticalSize, inset: inset, gap: gap) {
            placeVertical(main, size: verticalSize, on: side, selection: selection, inset: inset, gap: gap)
            layoutOptions(beside: main.frame, side: side, inset: inset, gap: gap)
            return
        }

        // 4. 四处都没位置 → 横排贴到选区上方，靠 `placeHorizontal` 的夹取收进画布。
        let size = measureMainToolbar(vertical: false)
        placeHorizontal(main, size: size, below: selection, inset: inset, gap: gap, above: true)
        layoutOptions(beside: main.frame, side: nil, inset: inset, gap: gap, above: true)
    }

    /// 量一次主工具栏在某个方向上的尺寸（`isVerticalLayout` 变了要让它先重新排一遍）。
    func measureMainToolbar(vertical: Bool) -> CGSize {
        guard let main = mainToolbarHost, let model = toolbarModel else { return .zero }
        if model.isVerticalLayout != vertical {
            model.isVerticalLayout = vertical
            main.layoutSubtreeIfNeeded()
        }
        return main.fittingSize
    }

    /// 横排：水平居中于选区，放在选区下面（`above = true` 时放上面）。
    func placeHorizontal(
        _ main: NSView,
        size: CGSize,
        below selection: CGRect,
        inset: CGFloat,
        gap: CGFloat,
        above: Bool = false
    ) {
        var origin = CGPoint(
            x: selection.midX - size.width / 2,
            y: above ? selection.maxY + gap : selection.minY - size.height - gap
        )
        origin.x = min(
            max(origin.x, bounds.minX + inset),
            max(bounds.minX + inset, bounds.maxX - size.width - inset)
        )
        origin.y = min(max(origin.y, bounds.minY + inset), bounds.maxY - size.height - inset)
        main.frame = CGRect(origin: origin, size: size)
    }

    /// 竖排能停在哪一侧？优先右侧，其次左侧；都放不下返回 nil。
    func verticalDockSide(
        for selection: CGRect,
        mainSize: CGSize,
        inset: CGFloat,
        gap: CGFloat
    ) -> VerticalDockSide? {
        guard mainSize.width > 0, mainSize.height > 0 else { return nil }
        // 竖排要够高（工具栏很长），也要在选区旁边放得下。
        guard mainSize.height <= bounds.height - inset * 2 else { return nil }
        let optionsSize = visibleOptionsSize()
        let columnWidth = mainSize.width + (optionsSize.width > 0 ? gap + optionsSize.width : 0)
        let roomLeft = selection.minX - bounds.minX
        let roomRight = bounds.maxX - selection.maxX
        if roomRight >= columnWidth + gap + inset { return .right }
        if roomLeft >= columnWidth + gap + inset { return .left }
        return nil
    }

    /// 竖排：贴边停靠，整体在竖直方向居中于选区（并夹进画布）。
    func placeVertical(
        _ main: NSView,
        size: CGSize,
        on side: VerticalDockSide,
        selection: CGRect,
        inset: CGFloat,
        gap: CGFloat
    ) {
        // **贴着选区**摆（不是贴屏幕边）：选区右边放不下才轮到左边，两边都放不下则走兜底。
        let x = side == .right ? selection.maxX + gap : selection.minX - gap - size.width
        var y = selection.midY - size.height / 2
        y = min(max(y, bounds.minY + inset), max(bounds.minY + inset, bounds.maxY - size.height - inset))
        main.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    enum VerticalDockSide {
        case left
        case right
    }

    /// 二级菜单当前的尺寸（不显示时为零）。
    func visibleOptionsSize() -> CGSize {
        guard let options = optionsToolbarHost, let model = toolbarModel, model.isSubToolbarVisible
        else { return .zero }
        options.layoutSubtreeIfNeeded()
        return options.fittingSize
    }

    /// 摆二级菜单：贴着主工具栏。
    ///
    /// - 横排（`side == nil`）：居中挂在主栏的**外侧**——主栏在选区下面（`above == false`）就挂在
    ///   主栏更下面，主栏在选区上面（`above == true`）就挂在主栏更上面，总之别往选区里挤；
    ///   那一侧放不下才翻回主栏与选区之间。
    /// - 竖排：也跟着竖排，挂在主栏**外侧**（离选区远的那一边），与主栏上下居中。
    func layoutOptions(
        beside mainFrame: CGRect,
        side: VerticalDockSide?,
        inset: CGFloat,
        gap: CGFloat,
        above: Bool = false
    ) {
        guard let options = optionsToolbarHost, let model = toolbarModel, model.isSubToolbarVisible else {
            optionsToolbarHost?.isHidden = true
            return
        }
        options.isHidden = false
        let size = visibleOptionsSize()
        guard size.width > 0, size.height > 0 else { return }

        if let side {
            // 主栏贴着选区，二级菜单挂在主栏**外侧**（离选区远的那一边），别挤在选区和主栏中间；
            // 竖直方向与主栏**上下居中**（主栏本身相对选区居中，这样两条栏看着是一体的）。
            var x = side == .right ? mainFrame.maxX + gap : mainFrame.minX - gap - size.width
            x = min(max(x, bounds.minX + inset), max(bounds.minX + inset, bounds.maxX - size.width - inset))
            let y = min(
                max(mainFrame.midY - size.height / 2, bounds.minY + inset),
                max(bounds.minY + inset, bounds.maxY - size.height - inset)
            )
            options.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            return
        }

        let x = min(
            max(mainFrame.midX - size.width / 2, bounds.minX + inset),
            max(bounds.minX + inset, bounds.maxX - size.width - inset)
        )
        let outer = above ? mainFrame.maxY + inset : mainFrame.minY - inset - size.height
        let inner = above ? mainFrame.minY - inset - size.height : mainFrame.maxY + inset
        let outerFits = above
            ? outer + size.height <= bounds.maxY - inset
            : outer >= bounds.minY + inset
        var y = outerFits ? outer : inner
        y = min(max(y, bounds.minY + inset), max(bounds.minY + inset, bounds.maxY - size.height - inset))
        options.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Eraser (see compose)

    // MARK: Inline geometry    // MARK: Inline geometry

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

    /// 统一的原地鼠标处理：先命中已有对象（任意工具下都可编辑），空白处才新建。
    func inlineMouseDown(_ point: CGPoint, clickCount: Int) {
        // 点别处一律先把正在编辑的文字落地。
        commitPendingInlineText()
        let crop = annotationPoint(from: point)
        let tool = toolbarModel?.tool

        // 橡皮：画笔式擦除（按绘制顺序擦除并恢复底图）。
        if tool == .eraser {
            guard let selection, selection.contains(point) else { return }
            commitPendingInlineText()
            pushUndo()
            erasing = true
            lastErasePoint = crop
            let radius = max(3, (toolbarModel?.eraserSize ?? 28) / 2 * snapshot.effectiveScale)
            let eraserAnnotation = Annotation(
                kind: .eraser(points: [crop], radius: radius),
                color: .white,
                lineWidth: radius * 2
            )
            annotations.append(eraserAnnotation)
            updateAnnotationLayer()
            return
        }

        // 文本工具：点已有文字直接改字；点别处（哪怕压着一条别的标注）都在这儿新建文字。
        // 不能让「命中已有标注」把点击吃掉——否则想给模糊块补一句说明就永远点不出输入框。
        if tool == .text {
            if let hit = inlineAnnotation(at: crop), case .text = hit.kind {
                selectedID = hit.id
                beginInlineText(at: textOrigin(of: hit), editing: hit)
                inlineEditDrag = .none
                updateInlineSelectionLayers()
                return
            }
            guard let selection, selection.contains(point) else { return }
            inlineStart = crop
            inlineDragging = true
            annotationDraft = nil
            updateAnnotationLayer()
            updateInlineSelectionLayers()
            return
        }

        // 1) 选中对象 + 命中控制点 → 缩放 / 旋转 / 端点（非自由涂抹工具下）
        let activeTarget = selectedAnnotation ?? (hoveredAnnotationID.flatMap { id in annotations.first { $0.id == id } })
        if tool != .pen, tool != .highlight,
            let target = activeTarget,
            let handle = inlineHitHandle(target, at: crop)
        {
            selectedID = target.id
            syncToolbarToAnnotation(target, updateTool: false)
            pushUndo()
            switch handle {
            case .rotate:
                let angle = atan2(crop.y - target.center.y, crop.x - target.center.x)
                inlineEditDrag = .rotating(id: target.id, startAngle: angle, original: target)
            case .arrowStart, .arrowEnd, .arrowControl, .lineStart, .lineEnd, .lineControl, .counterLeader:
                inlineEditDrag = .endpoint(id: target.id, handle: handle, original: target)
            default:
                inlineEditDrag = .resizing(id: target.id, handle: handle, original: target)
            }
            updateInlineSelectionLayers()
            return
        }

        // 2) 命中已有标注 → 选中并移动（非自由涂抹工具下）
        if tool != .pen, tool != .highlight, let hit = inlineAnnotation(at: crop) {
            selectedID = hit.id
            syncToolbarToAnnotation(hit, updateTool: false)
            if clickCount >= 2, case .text = hit.kind {
                beginInlineText(at: textOrigin(of: hit), editing: hit)
                inlineEditDrag = .none
                updateInlineSelectionLayers()
                return
            }
            pushUndo()
            inlineEditDrag = .moving(id: hit.id, start: crop, original: hit)
            updateInlineSelectionLayers()
            return
        }

        // 3) 空白：清空选中；若当前未选工具则支持双击完成 / 拖动选框；若选了绘制工具则开始新标注
        selectedID = nil
        inlineEditDrag = .none
        updateInlineSelectionLayers()
        guard let tool else {
            if clickCount >= 2 {
                confirmInline()
                return
            }
            if restoredBaseImage == nil, let selection, selection.contains(point) {
                pushUndo()
                interaction = .moving(
                    grabOffset: CGSize(
                        width: point.x - selection.minX,
                        height: point.y - selection.minY
                    ),
                    original: selection
                )
            }
            return
        }

        // 绘制工具必须在选区内点击才能开始绘制！选区外（包括工具栏周围）点击绝不开始绘制。
        guard let selection, selection.contains(point) else { return }
        guard tool.isDrawing else { return }

        commitPendingInlineText()
        inlineStart = crop
        inlineDragging = true
        annotationDraft = makeInlineDraft(start: crop, current: crop)
        updateAnnotationLayer()
    }

    func inlineMouseDragged(_ point: CGPoint) {
        let crop = annotationPoint(from: point)

        if erasing {
            if let last = annotations.last, case .eraser(var points, let radius) = last.kind {
                points.append(crop)
                annotations[annotations.count - 1].kind = .eraser(points: points, radius: radius)
            }
            lastErasePoint = crop
            updateAnnotationLayer()
            return
        }

        if inlineDragging, let model = toolbarModel {
            // 画笔与荧光笔都是**连续笔迹**：一路把点攒起来，而不是只留起点终点。
            if model.tool == .pen, case .pen(var points) = annotationDraft?.kind {
                points.append(crop)
                annotationDraft?.kind = .pen(points: points)
            } else if model.tool == .highlight, case .highlight(var points) = annotationDraft?.kind {
                points.append(crop)
                annotationDraft?.kind = .highlight(points: points)
            } else {
                annotationDraft = makeInlineDraft(start: inlineStart, current: crop)
            }
            updateAnnotationLayer()
            return
        }

        switch inlineEditDrag {
        case .none:
            break
        case .moving(let id, let start, let original):
            let delta = CGSize(width: crop.x - start.x, height: crop.y - start.y)
            updateAnnotation(id) { _ in original.translated(by: delta) }
        case .resizing(let id, let handle, let original):
            updateAnnotation(id) { _ in
                original.resized(handle: handle, to: crop, lockAspect: false)
            }
        case .rotating(let id, let startAngle, let original):
            let angle = atan2(crop.y - original.center.y, crop.x - original.center.x)
            updateAnnotation(id) { _ in original.rotated(by: angle - startAngle) }
        case .endpoint(let id, let handle, let original):
            updateAnnotation(id) { _ in original.withEndpoint(handle, to: crop) }
        }
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }

    func inlineMouseUp(_ point: CGPoint) {
        if erasing {
            erasing = false
            lastErasePoint = nil
            return
        }

        if inlineDragging, let model = toolbarModel {
            inlineDragging = false
            if model.tool == .text {
                annotationDraft = nil
                updateAnnotationLayer()
                beginInlineText(at: inlineStart)
                return
            }
            if let draft = annotationDraft, isValidInlineDraft(draft) {
                pushUndo()
                annotations.append(draft)
                selectedID = draft.id
                syncToolbarToAnnotation(draft)
                if case .counter = draft.kind { inlineCounterValue += 1 }
            }
            annotationDraft = nil
            updateAnnotationLayer()
            updateInlineSelectionLayers()
            return
        }

        if case .none = inlineEditDrag { return }
        inlineEditDrag = .none
        updateInlineSelectionLayers()
    }

    // MARK: Inline text field

    /// 就地输入文字：**直接落在点击位置**，按最终的字号与颜色显示（所见即所得），
    /// 不弹任何面板、不铺底色，只有一圈很细的同色边框标出编辑框。
    func beginInlineText(at cropPoint: CGPoint, editing: Annotation? = nil) {
        guard let model = toolbarModel else { return }
        commitPendingInlineText()
        inlineTextOrigin = cropPoint
        inlineEditingTextID = editing?.id

        if let editing {
            model.color = editing.color
            model.textHasStroke = editing.textHasStroke
            model.textHasCallout = editing.textHasCallout
            if case .text(_, _, let size) = editing.kind {
                model.fontSize = size / snapshot.effectiveScale
            }
        }

        let existing: String
        if case .text(_, let string, _)? = editing?.kind {
            existing = string
        } else {
            existing = ""
        }

        let field = InlineTextField(frame: .zero)
        field.stringValue = existing
        field.target = self
        field.action = #selector(handleInlineTextCommit)
        field.onCancelScreenshot = { [weak self] in
            self?.onCancel?()
        }
        field.onCommit = { [weak self] in
            self?.commitPendingInlineText()
        }
        field.onTextWidthChange = { [weak self] in
            self?.fitInlineTextField()
        }
        applyInlineTextStyle(field, model: model)
        addSubview(field)
        textField = field
        fitInlineTextField()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inlineTextDidChange),
            name: NSControl.textDidChangeNotification,
            object: field
        )
        window?.makeFirstResponder(field)
        field.attachEditorObservers()
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }

    /// 字号 / 颜色 / 特效都跟最终渲染一致（系统字体 + 标注色 + 气泡底板/描边），这才是「所见即所得」。
    func applyInlineTextStyle(_ field: InlineTextField, model: InlineToolbarModel) {
        field.applyStyle(
            fontSize: model.fontSize,
            color: model.color,
            hasStroke: model.textHasStroke,
            hasCallout: model.textHasCallout
        )
    }

    /// 框贴着文字宽度与行高，保证打字与成图严格像素对齐。
    /// 支持中文拼音输入时的实时动态宽度自适应与气泡内边距补偿。
    func fitInlineTextField() {
        guard let field = textField else { return }
        let viewOrigin = viewPoint(fromAnnotation: inlineTextOrigin)
        field.fitToOrigin(viewOrigin, isFlipped: false)
    }

    @objc private func inlineTextDidChange() {
        fitInlineTextField()
    }

    @objc private func handleInlineTextCommit() {
        commitPendingInlineText()
    }

    func commitPendingInlineText() {
        guard let field = textField, let model = toolbarModel else { return }
        window?.makeFirstResponder(self)
        field.detachEditorObservers()
        NotificationCenter.default.removeObserver(
            self, name: NSControl.textDidChangeNotification, object: field
        )
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = inlineTextOrigin
        let editingID = inlineEditingTextID
        field.removeFromSuperview()
        textField = nil
        inlineEditingTextID = nil

        guard !string.isEmpty else {
            if let editingID {
                pushUndo()
                annotations.removeAll { $0.id == editingID }
            }
            updateAnnotationLayer()
            updateInlineSelectionLayers()
            return
        }

        pushUndo()
        if let editingID, let index = annotations.firstIndex(where: { $0.id == editingID }) {
            annotations[index] = annotations[index]
                .withText(string)
                .withTextStroke(model.textHasStroke)
                .withTextCallout(model.textHasCallout)
            selectedID = editingID
        } else {
            let annotation = Annotation(
                kind: .text(
                    origin: origin,
                    string: string,
                    fontSize: max(12, model.fontSize * snapshot.effectiveScale)
                ),
                color: model.color,
                lineWidth: model.lineWidth,
                arrowStyle: model.arrowStyle,
                shapeFillMode: model.shapeFillMode,
                textHasStroke: model.textHasStroke,
                textHasCallout: model.textHasCallout
            )
            annotations.append(annotation)
            selectedID = annotation.id
        }
        updateAnnotationLayer()
        updateInlineSelectionLayers()
    }
}
