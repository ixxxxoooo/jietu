import AppKit
import SwiftUI

/// 遮罩画布 — 原地编辑工具栏的装配、选项条与参数联动。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

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
}
