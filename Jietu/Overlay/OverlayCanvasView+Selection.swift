import AppKit

/// 遮罩画布 — 命中测试、鼠标/键盘事件与选区交互。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    var screen: NSScreen {
        NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID }
            ?? NSScreen.screens.first
            ?? NSScreen.main!
    }

    func updateHoveredWindow(at point: CGPoint) {
        let cgPoint = DisplayGeometry.cgPoint(fromLocal: point, screen: screen)
        let hit = WindowHitTester.frontmost(atCGPoint: cgPoint, in: session.windows)
        #if DEBUG
        if hit?.windowID != hoveredWindow?.windowID {
            print(
                "[canvas \(snapshot.displayID)] hover local=\(Self.describe(point))"
                    + " cg=\(Self.describe(cgPoint))"
                    + " -> \(hit.map { "\($0.ownerName)/\($0.title)" } ?? "nil")"
                    + " of \(session.windows.count) windows"
            )
        }
        #endif
        guard hit?.windowID != hoveredWindow?.windowID else { return }
        hoveredWindow = hit
        updateWindowHighlight()
    }

    #if DEBUG
    static func describe(_ point: CGPoint) -> String {
        String(format: "(%.0f,%.0f)", point.x, point.y)
    }
    #endif

    static let cameraCursor: NSCursor = {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        if let img = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = NSSize(width: 24, height: 24)
            let canvas = NSImage(size: size, flipped: false) { rect in
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.shadowBlurRadius = 2
                shadow.set()
                NSColor.white.set()
                img.draw(in: NSRect(x: 2, y: 2, width: 20, height: 20))
                return true
            }
            return NSCursor(image: canvas, hotSpot: NSPoint(x: 12, y: 12))
        }
        return .arrow
    }()

    func updateCursor(at point: CGPoint) {
        if phase == .annotating {
            if let selection, let handle = SelectionGeometry.handle(
                at: point,
                in: selection,
                tolerance: Theme.selectionHandleHitTolerance
            ) {
                SelectionCursor.cursor(for: handle).set()
                return
            }
            let crop = annotationPoint(from: point)
            let target = selectedAnnotation ?? (hoveredAnnotationID.flatMap { id in annotations.first { $0.id == id } })
            if let target, let handle = inlineHitHandle(target, at: crop) {
                SelectionCursor.cursor(forShapeHandle: handle).set()
                return
            }
            // 选中框的「边」（不在控制点上）→ 小手，提示这里按着能拖动整个对象挪位置。
            if let selected = selectedAnnotation, inlineBoxBorderContains(selected, crop) {
                NSCursor.openHand.set()
                return
            }
            // 文本工具：选区内点哪儿都能打字（含压在别的标注上的位置），给 I 形光标；
            // 选区外不能输入，仍是箭头。
            if toolbarModel?.tool == .text, let selection, selection.contains(point) {
                NSCursor.iBeam.set()
            } else {
                NSCursor.arrow.set()
            }
            return
        }
        if isWindowOnlyMode {
            Self.cameraCursor.set()
            return
        }
        if let selection, let handle = SelectionGeometry.handle(
            at: point,
            in: selection,
            tolerance: Theme.selectionHandleHitTolerance
        ) {
            SelectionCursor.cursor(for: handle).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInputArmed else { return }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func resetCursorRects() {
        if phase == .annotating { return }
        addCursorRect(bounds, cursor: isWindowOnlyMode ? Self.cameraCursor : .arrow)
    }

    // MARK: - Events

    override func mouseMoved(with event: NSEvent) {
        guard isInputArmed else { return }
        requestFocusIfNeeded()
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        if phase == .annotating {
            let crop = annotationPoint(from: point)
            let newHover = inlineAnnotation(at: crop)?.id
            if newHover != hoveredAnnotationID {
                hoveredAnnotationID = newHover
                updateInlineSelectionLayers()
            }
        }
        updateHoveredWindow(at: point)
        updateCrosshair()
        updateLoupe()
        updateCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        hoveredWindow = nil
        hoveredAnnotationID = nil
        updateInlineSelectionLayers()
        updateWindowHighlight()
        updateCrosshair()
        updateLoupe()
    }

    override func mouseDown(with event: NSEvent) {
        guard isInputArmed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            requestFocusIfNeeded()
            cursorPoint = point
            // 裁剪工具自己接管鼠标：在图上任意位置（含正中）按下就能拖出新的裁剪框。
            if cropMouseDown(point, clickCount: event.clickCount) {
                return
            }
            // 选区边缘优先接管：绿框还在，抓着边缘就是继续调区域，框内照旧用来标注。
            if let selection,
                let handle = SelectionGeometry.handle(
                    at: point,
                    in: selection,
                    tolerance: Theme.selectionHandleHitTolerance
                )
            {
                // 整段拖拽算一步撤销（裁剪工具内由完成裁剪统一入栈）。
                if toolbarModel?.tool != .crop {
                    pushUndo()
                }
                interaction = .resizing(handle: handle, original: selection)
                return
            }
            inlineMouseDown(point, clickCount: event.clickCount)
            return
        }
        requestFocusIfNeeded()
        cursorPoint = point

        if isWindowOnlyMode {
            interaction = .pressing(anchor: point)
            // 按下的瞬间收起吸附描边（单击命中窗口靠的是 `hoveredWindow` 状态，不影响）。
            updateWindowHighlight()
            return
        }

        if let selection {
            if let handle = SelectionGeometry.handle(
                at: point,
                in: selection,
                tolerance: Theme.selectionHandleHitTolerance
            ) {
                interaction = .resizing(handle: handle, original: selection)
                return
            }
            if selection.contains(point) {
                if event.clickCount >= 2 {
                    if isRegionPickMode {
                        firePauseSignal()
                    } else {
                        commit()
                    }
                    return
                }
                interaction = .moving(
                    grabOffset: CGSize(
                        width: point.x - selection.minX,
                        height: point.y - selection.minY
                    ),
                    original: selection
                )
                return
            }
            // 在选区外按下：清掉旧选区，开始框新的。
            self.selection = nil
            updateAllLayers()
            notifySelectionChanged()
        }

        interaction = .pressing(anchor: point)
        // 按下的那一刻就收掉吸附描边与窗口标签：视觉焦点交给鼠标开始操作的地方。
        // 只收画面、不动 `hoveredWindow`——单击（没拖过阈值）要按它截图整个窗口。
        updateWindowHighlight()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInputArmed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            // 裁剪工具正拖着一个新裁剪框 → 只更新框，不画标注。
            if cropMouseDragged(point, lockAspect: event.modifierFlags.contains(.shift)) {
                return
            }
            // 正在拖选区边缘 → 继续改区域；否则交给原地标注。
            if case .resizing(let handle, let original) = interaction {
                cursorPoint = point
                let clampBounds = (restoredBaseImage != nil ? restoredImageFrame : nil) ?? canvasBounds
                let updated = SelectionGeometry.resized(
                    original,
                    handle: handle,
                    to: point,
                    clampTo: clampBounds,
                    lockAspect: event.modifierFlags.contains(.shift)
                )
                // 用「上一次的选区」算增量：每次拖拽事件都只平移一次。
                applyRegionResize(from: selection ?? original, to: updated)
                return
            }
            if case .moving(let grabOffset, let original) = interaction {
                cursorPoint = point
                let delta = CGSize(
                    width: point.x - original.minX - grabOffset.width,
                    height: point.y - original.minY - grabOffset.height
                )
                let updated = SelectionGeometry.moved(original, by: delta, clampTo: canvasBounds)
                applyRegionResize(from: selection ?? original, to: updated)
                return
            }
            inlineMouseDragged(point)
            return
        }
        cursorPoint = point
        let lockAspect = event.modifierFlags.contains(.shift)

        switch interaction {
        case .pressing(let anchor):
            // 窗口专选模式下禁止拖出自由选区
            guard !isWindowOnlyMode else { break }
            if hypot(point.x - anchor.x, point.y - anchor.y) >= Theme.dragActivationDistance {
                interaction = .selecting(anchor: anchor)
                selection = SelectionGeometry.selectionRect(
                    from: anchor,
                    to: point,
                    clampTo: canvasBounds,
                    square: lockAspect
                )
            }
        case .selecting(let anchor):
            selection = SelectionGeometry.selectionRect(
                from: anchor,
                to: point,
                clampTo: canvasBounds,
                square: lockAspect
            )
        case .resizing(let handle, let original):
            selection = SelectionGeometry.resized(
                original,
                handle: handle,
                to: point,
                clampTo: canvasBounds,
                lockAspect: lockAspect
            )
        case .moving(let grabOffset, let original):
            let delta = CGSize(
                width: point.x - original.minX - grabOffset.width,
                height: point.y - original.minY - grabOffset.height
            )
            selection = SelectionGeometry.moved(original, by: delta, clampTo: canvasBounds)
        case .idle, .settled:
            break
        }

        updateDimPath()
        updateSelectionLayers()
        updateCrosshair()
        updateLoupe()
        updateHint()

        if isRegionPickMode {
            notifySelectionChanged()
            schedulePauseSignal()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isInputArmed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            // 裁剪框拖拽收手：框留着（不立刻裁），按 ↵ / 双击 / 「完成裁剪」才动刀。
            if cropMouseUp() {
                return
            }
            // 拖选区边缘或整体移动收手：回到「已定」状态，不把它当成一次标注。
            if case .resizing = interaction {
                interaction = .settled
                if restoredBaseImage != nil && toolbarModel?.tool != .crop {
                    applyDirectResizeCrop()
                }
                return
            }
            if case .moving = interaction {
                interaction = .settled
                return
            }
            inlineMouseUp(point)
            return
        }
        cursorPoint = point

        let wasSelecting: Bool
        if case .selecting = interaction {
            wasSelecting = true
        } else {
            wasSelecting = false
        }

        switch interaction {
        case .pressing:
            // 单击：命中窗口
            if let hoveredWindow {
                // 录屏：不拖也行——点哪个窗口就录哪个窗口。
                if isRecordMode {
                    let rect = DisplayGeometry.localRect(
                        fromCGRect: hoveredWindow.frameInCGPoints, screen: screen
                    ).intersection(canvasBounds)
                    guard !rect.isEmpty else {
                        interaction = .idle
                        return
                    }
                    selection = rect
                    interaction = .settled
                    updateAllLayers()
                    onRecordRegionPicked?(rect)
                    return
                }
                if isRegionPickMode {
                    selection = DisplayGeometry.localRect(
                        fromCGRect: hoveredWindow.frameInCGPoints,
                        screen: screen
                    ).intersection(canvasBounds)
                    // 先把选区视觉画出来再交付：滚动长图会把遮罩留着当取景框，
                    // 少了这一步绿框就不会出现。
                    updateAllLayers()
                    interaction = .settled
                    Self.rememberedSelection[snapshot.displayID] = selection
                    notifySelectionChanged()
                    firePauseSignal()
                    return
                }
                if inlineMode {
                    let rect = DisplayGeometry.localRect(
                        fromCGRect: hoveredWindow.frameInCGPoints,
                        screen: screen
                    ).intersection(canvasBounds)
                    guard !rect.isEmpty else {
                        interaction = .idle
                        return
                    }
                    selection = rect
                    interaction = .settled
                    Self.rememberedSelection[snapshot.displayID] = selection
                    updateAllLayers()
                    enterAnnotating()
                    return
                }
                onWindowSelected?(hoveredWindow)
                return
            }
            interaction = .idle
        case .selecting:
            if let rect = selection,
                rect.width >= Theme.minimumSelectionSize,
                rect.height >= Theme.minimumSelectionSize
            {
                interaction = .settled
            } else {
                selection = nil
                interaction = .idle
            }
        case .resizing, .moving:
            interaction = .settled
        case .idle, .settled:
            break
        }

        // 原地模式：鼠标一松开（拖拽结束）就弹出标注工具栏。
        if inlineMode, isSettled, phase == .selecting, selection != nil {
            enterAnnotating()
            return
        }

        // 浮窗预览模式：框选区域一松开鼠标就直接完成截图（不用双击 / 回车），交付浮窗与剪贴板。
        if !inlineMode, !isRegionPickMode, !isRecordMode, wasSelecting, isSettled, selection != nil {
            commit()
            return
        }

        // 滚动长图：松手也立刻把「手动 / 自动」浮出来（不用等鼠标停住，
        // 更不用按 ↵）；在点模式之前选区还能继续拖 / 缩放。
        if isRegionPickMode {
            if isSettled, let selection {
                Self.rememberedSelection[snapshot.displayID] = selection
                notifySelectionChanged()
                firePauseSignal()
            } else {
                cancelPauseSignal()
                notifySelectionChanged()
            }
            updateAllLayers()
            updateHoveredWindow(at: point)
            updateWindowHighlight()
            return
        }

        // 录屏：选区成型就把这块交给外面（控制条会停在「准备录制」，点开始才真开录）。
        if isRecordMode {
            if isSettled, let selection {
                onRecordRegionPicked?(selection)
            } else {
                selection = nil
                interaction = .idle
                updateAllLayers()
            }
            return
        }

        if isSettled, let selection {
            Self.rememberedSelection[snapshot.displayID] = selection
        }
        updateAllLayers()
        updateHoveredWindow(at: point)
        updateWindowHighlight()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInputArmed else { return }
        onCancel?()
    }
}
