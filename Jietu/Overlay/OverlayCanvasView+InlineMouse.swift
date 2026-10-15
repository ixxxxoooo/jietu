import AppKit

/// 遮罩画布 — 原地编辑的鼠标处理（按下 / 拖动 / 抬起）。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    /// 统一的原地鼠标处理：先命中已有对象（任意工具下都可编辑），空白处才新建。
    func inlineMouseDown(_ point: CGPoint, clickCount: Int) {
        // 点别处一律先把正在编辑的文字落地。先记下「点之前是否正在输入」：
        // 文本工具下这一次空白点击只负责**结束**编辑，不再顺手冒出一个新的空输入框
        // （否则旧框提交、原地又出现一个 24px 的小空框，看着就像文本框"缩"了）。
        let wasEditingText = textField != nil
        commitPendingInlineText()
        let crop = annotationPoint(from: point)
        let tool = toolbarModel?.tool
        pendingTextEditID = nil
        inlineDragMoved = false

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

        // 文本工具：点已有文字改字（点一下）/ 挪位置（拖一下）；点别处（哪怕压着一条别的
        // 标注）都在这儿新建文字。放在控制点判定之后，编辑点才拖得动大小。
        if tool == .text {
            if let hit = inlineAnnotation(at: crop), case .text = hit.kind {
                // 点一下改字、拖一下挪位置：先按「移动」起手，松手时没拖动过才转成改字。
                selectedID = hit.id
                pendingTextEditID = hit.id
                inlineEditDrag = .moving(id: hit.id, start: crop, original: hit)
                updateInlineSelectionLayers()
                return
            }
            // 刚结束一次文字编辑：这一下只是收尾，不再新建空框。
            if wasEditingText { return }
            guard let selection, selection.contains(point) else { return }
            inlineStart = crop
            inlineDragging = true
            annotationDraft = nil
            updateAnnotationLayer()
            updateInlineSelectionLayers()
            return
        }

        // 2) 点中「已选中对象的编辑框」→ 拖动整个对象。
        //    · 选择态（选择工具 / 未选工具）：框内任意处都能拖——未填充的矩形 / 椭圆内部
        //      本来也不算命中图形本身，没有这条就永远拖不动；
        //    · 绘制工具下：抓框**边**（有小手提示）也能拖走，框内部仍留给「画新图形」，
        //      否则想画一个叠在已有图形上的新图形时会误拖前一个。
        let isSelectionMode = tool == .select || tool == nil
        if let selected = selectedAnnotation,
            (isSelectionMode && inlineBoxContains(selected, crop))
                || inlineBoxBorderContains(selected, crop)
        {
            pushUndo()
            inlineEditDrag = .moving(id: selected.id, start: crop, original: selected)
            updateInlineSelectionLayers()
            return
        }

        // 3) 命中已有标注 → 选中并移动（非自由涂抹工具下）
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

        // 4) 空白：清空选中；若当前未选工具则支持双击完成 / 拖动选框；若选了绘制工具则开始新标注
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
            inlineDragMoved = true
            let delta = CGSize(width: crop.x - start.x, height: crop.y - start.y)
            updateAnnotation(id) { _ in original.translated(by: delta) }
        case .resizing(let id, let handle, let original):
            inlineDragMoved = true
            updateAnnotation(id) { _ in
                original.resized(handle: handle, to: crop, lockAspect: false)
            }
        case .rotating(let id, let startAngle, let original):
            inlineDragMoved = true
            let angle = atan2(crop.y - original.center.y, crop.x - original.center.x)
            updateAnnotation(id) { _ in original.rotated(by: angle - startAngle) }
        case .endpoint(let id, let handle, let original):
            inlineDragMoved = true
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

        // 文本工具：点一下（没拖动过）就进入改字；拖动过就当作移动，不改字。
        if let editID = pendingTextEditID {
            pendingTextEditID = nil
            inlineEditDrag = .none
            if !inlineDragMoved, let annotation = annotations.first(where: { $0.id == editID }) {
                selectedID = editID
                beginInlineText(at: textOrigin(of: annotation), editing: annotation)
            }
            updateInlineSelectionLayers()
            return
        }

        if case .none = inlineEditDrag { return }
        inlineEditDrag = .none
        updateInlineSelectionLayers()
    }
}
