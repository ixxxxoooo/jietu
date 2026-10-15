import AppKit

/// 遮罩画布 — 原地编辑的文字输入框。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

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
