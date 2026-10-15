import AppKit

/// 遮罩画布 — 原地标注编辑的主流程（进出标注态、撤销重做、compose、确认 / 取消）。
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
}
