import AppKit

/// 遮罩画布 — 标注阶段的滚轮与触控板缩放。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    override func scrollWheel(with event: NSEvent) {
        guard isInputArmed, phase == .annotating, selection != nil else {
            super.scrollWheel(with: event)
            return
        }

        let delta: CGFloat
        if event.hasPreciseScrollingDeltas {
            delta = event.scrollingDeltaY * 0.005
        } else {
            delta = event.deltaY * 0.05
        }
        guard abs(delta) > 0.0001 else { return }

        let factor = max(0.2, min(5.0, 1.0 + delta))
        let point = convert(event.locationInWindow, from: nil)
        zoomSelection(by: factor, at: point)
    }

    override func magnify(with event: NSEvent) {
        guard isInputArmed, phase == .annotating, selection != nil else {
            super.magnify(with: event)
            return
        }

        let factor = 1.0 + event.magnification
        guard factor > 0.01 else { return }
        let point = convert(event.locationInWindow, from: nil)
        zoomSelection(by: factor, at: point)
    }

    func zoomSelection(by factor: CGFloat, at point: CGPoint) {
        guard let selection, selection.width > 0, selection.height > 0 else { return }
        let currentBase = restoredBaseImage ?? cropImage
        guard let image = currentBase else { return }

        // 若之前尚未接管底图（普通截图原地编辑），缩放时提升到底图图层实现无拉伸高保真缩放
        if restoredBaseImage == nil {
            restoredBaseImage = image
            restoredImageFrame = selection
            preparePreviewBase()
        }

        let baseFrame = restoredImageFrame ?? selection
        let mouseInSelection = CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)
        let aspectRatio = selection.width / selection.height

        let screen = NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID } ?? NSScreen.main
        let screenSize = screen?.visibleFrame.size ?? CGSize(width: 1920, height: 1080)
        let maxSize = CGSize(width: screenSize.width * 3, height: screenSize.height * 3)

        let newSelection = PinGeometry.zoomedFrame(
            currentFrame: selection,
            factor: factor,
            mouseLocationInWindow: mouseInSelection,
            aspectRatio: aspectRatio,
            minSide: 60,
            maxSize: maxSize
        )

        guard newSelection != selection else { return }

        let scale = newSelection.width / selection.width
        let newBaseFrame = CGRect(
            x: newSelection.minX + (baseFrame.minX - selection.minX) * scale,
            y: newSelection.minY + (baseFrame.minY - selection.minY) * scale,
            width: baseFrame.width * scale,
            height: baseFrame.height * scale
        )

        self.selection = newSelection
        self.restoredImageFrame = newBaseFrame

        updateRestoredImageLayer()
        updateDimPath()
        updateSelectionLayers()
        updateAnnotationLayer()
        updateInlineSelectionLayers()
        fitInlineTextField()
        layoutToolbars()
    }

    override func keyDown(with event: NSEvent) {
        guard isInputArmed else { return }
        if phase == .annotating {
            // 撤销 / 重做走设置页配的那两个组合键（默认 ⌘Z / ⇧⌘Z）。
            // 正在改文字时不抢：那时 field editor 才是第一响应者，⌘Z 该撤的是打的字。
            if textField == nil {
                if let hotkey = editorShortcuts.undo, hotkey.matches(event) {
                    inlineUndo()
                    return
                }
                if let hotkey = editorShortcuts.redo, hotkey.matches(event) {
                    inlineRedo()
                    return
                }
                if event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
                    event.charactersIgnoringModifiers?.lowercased() == "s"
                {
                    if let image = currentAnnotatedImage() {
                        onSaveImage?(image)
                        return
                    }
                }
            }
            switch event.keyCode {
            case 53: // Esc
                if toolbarModel?.tool == .crop {
                    cancelCrop()
                    return
                }
                onCancel?()
            case 36, 76: // Return
                if toolbarModel?.tool == .crop {
                    applyCrop()
                    return
                }
                confirmInline()
            case 51, 117: // Delete
                if let selectedID {
                    pushUndo()
                    annotations.removeAll { $0.id == selectedID }
                    self.selectedID = nil
                    updateAnnotationLayer()
                    updateInlineSelectionLayers()
                } else {
                    inlineUndo()
                }
            default:
                super.keyDown(with: event)
            }
            return
        }
        switch event.keyCode {
        case 53: // kVK_Escape
            onCancel?()
        case 36, 76: // Return / keypad Enter
            // 滚动长图：↵ 只当「我选好了」，浮出模式条；真正的开始交给手动 / 自动。
            if isRegionPickMode {
                firePauseSignal()
            } else {
                commit()
            }
        case 48: // Tab
            restoreRememberedSelection()
        case 49: // Space: 在自由框选与窗口截取模式之间切换
            if selection == nil && !isRegionPickMode {
                isWindowOnlyMode.toggle()
            }
        case 123, 124, 125, 126: // 方向键
            nudge(keyCode: event.keyCode, large: event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }
}
