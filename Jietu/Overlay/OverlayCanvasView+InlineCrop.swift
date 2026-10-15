import AppKit

/// 遮罩画布 — 原地编辑的裁剪工具（框选、拖动、执行与取消）。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

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
}
