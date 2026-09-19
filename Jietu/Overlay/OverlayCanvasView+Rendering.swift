import AppKit

/// 遮罩画布 — 渲染与图层更新。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    func updateAllLayers() {
        updateDimPath()
        updateRestoredImageLayer()
        updateSelectionLayers()
        updateCrosshair()
        updateLoupe()
        updateHint()
    }

    func updateRestoredImageLayer() {
        guard let restoredBaseImage, let selection else {
            restoredContainerLayer.isHidden = true
            restoredImageLayer.contents = nil
            return
        }
        // 底图**整张**画在它自己的 frame 上，不跟着裁剪框裁。
        //
        // 裁剪框只标记「将要保留哪一块」，框外交给压暗层压暗就够了。要是把框外裁掉，
        // 露出来的是下面那张冻结屏幕（压暗 α 只有 0.45，还看得清），看着就成了
        // 「在屏幕上重新框一块区域」，而不是「在这张图上裁」。
        let baseFrame = restoredImageFrame ?? selection
        restoredContainerLayer.frame = baseFrame
        restoredContainerLayer.isHidden = false
        restoredImageLayer.frame = CGRect(origin: .zero, size: baseFrame.size)
        restoredImageLayer.contents = restoredBaseImage
    }

    func updateDimPath() {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole = dimHoleRect {
            // even-odd 挖洞：洞口用圆角只在「还没定选区、只是吸附到窗口」那一种情况下，
            // 让用户先看到清晰明亮的将截窗口内容。
            path.addPath(
                dimHoleIsRoundedWindow
                    ? CGPath(roundedRect: hole, cornerWidth: 10, cornerHeight: 10, transform: nil)
                    : CGPath(rect: hole, transform: nil)
            )
        }
        dimLayer.path = path
    }

    /// 压暗层挖的洞。**裁剪时是整张图**（不是裁剪框）：框只标记「要保留哪一块」，图本身一直亮着，
    /// 免得框一缩小、框外就压暗露出底下的冻结屏幕，分不清图到哪儿为止；其余时候是选区 / 吸附到的窗口。
    var dimHoleRect: CGRect? {
        if let cropFrame { return cropFrame }
        if let selection { return selection }
        return hoveredWindowLocalRect
    }

    /// 洞口是不是那种「还没定选区、只是吸附到了窗口」的圆角预览。
    var dimHoleIsRoundedWindow: Bool {
        cropFrame == nil && selection == nil && hoveredWindowLocalRect != nil
    }

    /// 鼠标下窗口在本显示器内的矩形（已裁进画布），没有则 nil。
    ///
    /// 只在「还没有选区」时用于悬停预览；一旦点选/框选成型就收起高亮，
    /// 选中的窗口不再有蓝色染色（与框选保持一致）。
    var hoveredWindowLocalRect: CGRect? {
        guard !isSettled, selection == nil, let hoveredWindow else { return nil }
        let rect = DisplayGeometry.localRect(
            fromCGRect: hoveredWindow.frameInCGPoints,
            screen: screen
        )
        let clipped = rect.intersection(canvasBounds)
        return clipped.isEmpty ? nil : clipped
    }

    /// 鼠标按下之后的这段时间，吸附预览（描边 + 窗口标签）要**当场收掉**。
    ///
    /// 用户按下就是要开始操作了，视觉焦点得跟到鼠标开始操作的地方去；
    /// 不然拖框拖到一半，那个绿圈还赖在原来的窗口上（用户报的就是这个）。
    /// 只收**画面**：`hoveredWindow` 状态留着，单击命中窗口那条路还要用它。
    var isPressPreviewSuppressed: Bool {
        switch interaction {
        case .idle, .settled:
            return false
        case .pressing, .selecting, .resizing, .moving:
            return true
        }
    }

    /// 吸附预览该画的窗口矩形。
    ///
    /// 与 `hoveredWindowLocalRect` 的区别只有一条：按下之后收起。
    /// 压暗层的洞口（`updateDimPath`）仍然按 `hoveredWindowLocalRect` 算——
    /// 按下瞬间就把窗口重新压暗会闪一下，那一片该一直亮到选区接管为止。
    var hoveredWindowPreviewRect: CGRect? {
        isPressPreviewSuppressed ? nil : hoveredWindowLocalRect
    }

    func updateSelectionLayers() {
        updateCropFrameBorder()
        guard let selection else {
            selectionBorderOuterLayer.isHidden = true
            selectionBorderInnerLayer.isHidden = true
            handlesLayer.path = nil
            sizeLabelLayer.isHidden = true
            return
        }


        selectionBorderOuterLayer.isHidden = false
        selectionBorderInnerLayer.isHidden = true
        // 绿色虚线选框。
        selectionBorderOuterLayer.path = CGPath(rect: selection, transform: nil)

        let path = CGMutablePath()
        let size = Theme.selectionHandleSize
        for handle in SelectionHandle.allCases {
            let center = handle.center(in: selection)
            // 圆形控制点。
            path.addPath(
                CGPath(
                    ellipseIn: CGRect(
                        x: center.x - size / 2,
                        y: center.y - size / 2,
                        width: size,
                        height: size
                    ),
                    transform: nil
                )
            )
        }
        handlesLayer.path = path

        updateSizeLabel(selection)
    }

    /// 裁剪时给底图画一条外框：框缩到图中间以后，这条边框就是「图到哪儿为止」的参照。
    ///
    /// 只在裁剪中、且裁剪框确实比图小时才画——框和图的边界重合时再画一条纯属重复。
    func updateCropFrameBorder() {
        guard let cropFrame else {
            baseFrameBorderLayer.isHidden = true
            baseFrameBorderLayer.path = nil
            return
        }
        let isRedundant = selection.map { $0 == cropFrame } ?? true
        baseFrameBorderLayer.isHidden = isRedundant
        baseFrameBorderLayer.path = isRedundant ? nil : CGPath(rect: cropFrame, transform: nil)
    }

    func updateSizeLabel(_ selection: CGRect) {
        guard !isScrollCaptureChrome else { return }
        let pixelSize: CGSize
        if let restored = restoredBaseImage, let baseFrame = restoredImageFrame, baseFrame.width > 0, baseFrame.height > 0 {
            let scaleX = CGFloat(restored.width) / baseFrame.width
            let scaleY = CGFloat(restored.height) / baseFrame.height
            pixelSize = CGSize(
                width: (selection.width * scaleX).rounded(),
                height: (selection.height * scaleY).rounded()
            )
        } else {
            pixelSize = CGSize(
                width: (selection.width * snapshot.effectiveScale).rounded(),
                height: (selection.height * snapshot.effectiveScale).rounded()
            )
        }
        let text = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
        sizeLabelLayer.set(text: text)
        let size = sizeLabelLayer.calculateSize()

        // 默认放在选区上方外侧；若触顶（靠近屏幕顶部）则移到选区内部左上。
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        if origin.y + size.height > bounds.maxY - 2 {
            origin.y = selection.maxY - size.height - 6
        }
        origin.x = min(max(origin.x, bounds.minX + 2), bounds.maxX - size.width - 2)
        origin.y = min(max(origin.y, bounds.minY + 2), bounds.maxY - size.height - 2)

        sizeLabelLayer.frame = CGRect(origin: origin, size: size)
        sizeLabelLayer.isHidden = false
    }

    func updateCrosshair() {
        crosshairLayer.path = nil
    }
}
