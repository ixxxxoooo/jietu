import AppKit

/// 遮罩画布 — 跟随光标的像素放大镜卡片（镜面 + 坐标 / 区域 / 色值）。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    /// 放大镜：跟随光标，只在「还没定选区」的框选阶段出现。
    func updateLoupe() {
        guard let card = loupeCardHost else { return }

        CATransaction.begin()
        // 跟手的东西一律不走隐式动画：否则首帧会从原点滑过来，移动时也慢半拍。
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let shouldShow = cursorPoint != nil && !isSettled && !isScrollCaptureChrome
            && phase == .selecting
        guard shouldShow, let cursorPoint else {
            card.isHidden = true
            return
        }

        let cursorPixel = updateLoupeMirror(at: cursorPoint)
        updateLoupeReadout(pixel: cursorPixel)

        let frame = loupeCardFrame(near: cursorPoint, size: card.fittingSize)
        card.frame = frame
        card.isHidden = false

        #if DEBUG
        loupeDebugState = DebugLoupeState(
            frame: loupeMirrorFrame(in: frame),
            sourceOrigin: loupeSourceOrigin ?? .zero,
            cursorPixel: cursorPixel,
            cell: loupeCardModel.cursorCell,
            cellSide: PixelLoupe.cellSide,
            hex: loupeCardModel.hex
        )
        #endif
    }

    /// 换镜面：以光标像素为正中取一格窗口，贴边时把窗口夹回图像内（光标格随之偏离中心）。
    ///
    /// 返回光标的像素坐标（图像像素、原点左上）。
    private func updateLoupeMirror(at localPoint: CGPoint) -> CGPoint {
        let image = snapshot.image
        let cells = PixelLoupe.cells
        let center = snapshot.pixelPoint(fromLocalPoint: localPoint)
        let cursorPixel = CGPoint(x: center.x.rounded(.down), y: center.y.rounded(.down))

        let span = CGFloat(cells - 1) / 2
        let origin = CGPoint(
            x: min(max(cursorPixel.x - span, 0), max(0, CGFloat(image.width - cells))),
            y: min(max(cursorPixel.y - span, 0), max(0, CGFloat(image.height - cells)))
        )
        loupeCardModel.cursorCell = CGPoint(
            x: min(max(cursorPixel.x - origin.x, 0), CGFloat(cells - 1)),
            y: min(max(cursorPixel.y - origin.y, 0), CGFloat(cells - 1))
        )

        // 镜面就是采样窗口那一小块（13×13，`cropping` 是惰性的）：窗口没换就不重新裁。
        if loupeSourceOrigin != origin {
            loupeSourceOrigin = origin
            loupeCardModel.image = image.cropping(
                to: CGRect(origin: origin, size: CGSize(width: cells, height: cells))
            )
        }
        return cursorPixel
    }

    /// 读数：坐标 / 区域 / 色值。
    ///
    /// 取色只在**跨过像素**时才做（鼠标移动不额外解码大图），天然节流。
    private func updateLoupeReadout(pixel: CGPoint) {
        let coordinate = String(format: "(%.0f, %.0f)", pixel.x, pixel.y)
        // 「区域」= 现在按下去会截到的那块：选框 / 悬停窗口，都没有就显示占位。
        let regionPoints = selection ?? hoveredWindowLocalRect
        let region = regionPoints.map {
            String(
                format: "%.0f × %.0f",
                ($0.width * snapshot.effectiveScale).rounded(),
                ($0.height * snapshot.effectiveScale).rounded()
            )
        } ?? "—"

        if loupeCardModel.coordinate != coordinate { loupeCardModel.coordinate = coordinate }
        if loupeCardModel.region != region { loupeCardModel.region = region }

        guard lastSampledPixel != pixel else { return }
        lastSampledPixel = pixel
        let sample = PixelSampler.sample(snapshot.image, atPixel: pixel)
        loupeCardModel.hex = sample?.hexString
        loupeCardModel.swatch = sample?.nsColor
    }

    /// 把卡片摆在光标旁边：镜面紧挨光标（贴边翻到另一侧），读数挂在镜面下面。
    ///
    /// 卡片的排布由 `PixelLoupeCard` 定死（镜面在左上角、读数在下方），这里只负责整块摆位，
    /// 所以先按「镜面贴光标」算出位置，再换成卡片自己的 frame。
    private func loupeCardFrame(near cursor: CGPoint, size: CGSize) -> CGRect {
        let inset = Theme.Spacing.md
        var mirror = CGRect(
            origin: CGPoint(x: cursor.x + PixelLoupe.gap, y: cursor.y + PixelLoupe.gap),
            size: CGSize(width: PixelLoupe.side, height: PixelLoupe.side)
        )
        if mirror.maxX + PixelLoupe.padding + (size.width - PixelLoupe.side - PixelLoupe.padding * 2)
            > bounds.maxX - inset
        {
            mirror.origin.x = cursor.x - PixelLoupe.gap - PixelLoupe.side
        }
        if mirror.maxY + PixelLoupe.padding > bounds.maxY - inset {
            mirror.origin.y = cursor.y - PixelLoupe.gap - PixelLoupe.side
        }

        var origin = CGPoint(
            x: mirror.minX - PixelLoupe.padding,
            y: mirror.maxY + PixelLoupe.padding - size.height
        )
        origin.x = min(
            max(origin.x, bounds.minX + inset),
            max(bounds.minX + inset, bounds.maxX - size.width - inset)
        )
        origin.y = min(
            max(origin.y, bounds.minY + inset),
            max(bounds.minY + inset, bounds.maxY - size.height - inset)
        )
        return CGRect(origin: origin, size: size)
    }

    /// 镜面在卡片里的 frame（画布坐标）—— 自检要靠它把「镜面里的每一格」对回屏幕像素。
    func loupeMirrorFrame(in cardFrame: CGRect) -> CGRect {
        let origin = PixelLoupe.mirrorOrigin(in: cardFrame.height)
        return CGRect(
            x: cardFrame.minX + origin.x,
            y: cardFrame.minY + origin.y,
            width: PixelLoupe.side,
            height: PixelLoupe.side
        )
    }

    func updateWindowHighlight() {
        // 压暗层也要跟着重算（洞口就是被吸附的窗口）。
        updateDimPath()

        guard let window = hoveredWindow, let clipped = hoveredWindowPreviewRect else {
            windowHighlightLayer.isHidden = true
            windowLabelLayer.isHidden = true
            return
        }

        windowHighlightLayer.isHidden = false
        windowHighlightLayer.path = CGPath(roundedRect: clipped, cornerWidth: 10, cornerHeight: 10, transform: nil)

        let text = "\(window.displayName)   \(Int(window.frameInCGPoints.width))×\(Int(window.frameInCGPoints.height))"
        let width = min(bounds.width - 20, max(120, CGFloat(text.count) * 7.2 + 16))
        let height: CGFloat = 20
        let origin = CGPoint(
            x: min(max(clipped.minX, bounds.minX + 6), bounds.maxX - width - 6),
            y: max(clipped.maxY - height - 6, bounds.minY + 6)
        )
        windowLabelLayer.string = text
        windowLabelLayer.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        windowLabelLayer.alignmentMode = .center
        windowLabelLayer.isHidden = false
    }

    func updateHint() {
        guard !isScrollCaptureChrome else { return }
        let size = snapshot.pixelSize
        var text = L10n.overlayDisplayInfo(
            displayIndex,
            displayCount,
            size.width,
            size.height,
            snapshot.effectiveScale
        )
        if isRecordMode && isWindowOnlyMode {
            text += L10n.overlayClickWindowRecord
        } else if isRecordMode {
            text += L10n.overlayDragAreaRecord
        } else if isRegionPickMode {
            text += selection == nil
                ? L10n.overlayScrollDragHint
                : L10n.overlayScrollAdjustHint
        } else if isWindowOnlyMode {
            text += L10n.overlayClickWindowCapture
        } else {
            text += selection == nil
                ? L10n.overlayDragCapture
                : L10n.overlaySelectionConfirm
        }
        let width = min(bounds.width - 40, max(420, CGFloat(text.count) * 7.4))
        hintLayer.string = text
        hintLayer.frame = CGRect(
            x: bounds.midX - width / 2,
            y: bounds.maxY - 56,
            width: width,
            height: 24
        )
    }
}