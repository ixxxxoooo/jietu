import AppKit

/// 遮罩画布 — 跟随光标的像素放大镜。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    var loupeLayers: [CALayer] {
        [
            loupeShadowLayer, loupeBorderLayer, loupeImageLayer, loupeGridDarkLayer,
            loupeGridLightLayer, loupeGuideLayer, loupeCellShadowLayer, loupeCellLayer,
            loupePanelLayer, loupeCoordinateLayer, loupeRegionLayer, loupeColorLayer,
            loupeSwatchLayer,
        ]
    }

    /// 放大镜：跟着光标，只在「还没定选区」的框选阶段出现。
    func updateLoupe() {
        CATransaction.begin()
        // 跟手的东西一律不走隐式动画（见 loupeNoActions）：否则首帧会从图层原点滑过来。
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let shouldShow = cursorPoint != nil && !isSettled && !isScrollCaptureChrome
            && phase == .selecting
        for layer in loupeLayers {
            layer.isHidden = !shouldShow
        }
        guard shouldShow, let cursorPoint else { return }

        let image = snapshot.image
        let side = Loupe.side
        let cells = CGFloat(Loupe.cells)
        let cellSide = side / cells
        // 光标所在的图像像素（原点左上）。
        let center = snapshot.pixelPoint(fromLocalPoint: cursorPoint)
        let cursorPixel = CGPoint(x: center.x.rounded(.down), y: center.y.rounded(.down))

        // 以光标像素为正中取一格窗口；贴边时把窗口夹回图像内（光标格会随之偏离中心）。
        let span = CGFloat(Loupe.cells - 1) / 2
        let originX = min(
            max(cursorPixel.x - span, 0), max(0, CGFloat(image.width) - cells)
        )
        let originY = min(
            max(cursorPixel.y - span, 0), max(0, CGFloat(image.height) - cells)
        )
        loupeImageLayer.contentsRect = LoupeGeometry.contentsRect(
            sourceOrigin: CGPoint(x: originX, y: originY),
            cells: Loupe.cells,
            imageSize: snapshot.pixelSize
        )

        let cellX = min(max(cursorPixel.x - originX, 0), cells - 1)
        let cellY = min(max(cursorPixel.y - originY, 0), cells - 1)
        let cellRect = CGRect(
            x: cellX * cellSide,
            y: side - (cellY + 1) * cellSide,
            width: cellSide,
            height: cellSide
        )
        loupeGridDarkLayer.path = Self.loupeGridPath
        loupeGridLightLayer.path = Self.loupeGridPath
        let guide = CGMutablePath()
        guide.addRect(CGRect(x: 0, y: cellRect.minY, width: side, height: cellSide))
        guide.addRect(CGRect(x: cellRect.minX, y: 0, width: cellSide, height: side))
        loupeGuideLayer.path = guide
        loupeCellShadowLayer.path = CGPath(rect: cellRect, transform: nil)
        loupeCellLayer.path = CGPath(rect: cellRect, transform: nil)

        // 跟在光标右上角，贴边时翻到另一侧并夹在屏幕内。
        var origin = CGPoint(x: cursorPoint.x + Loupe.gap, y: cursorPoint.y + Loupe.gap)
        if origin.x + side > bounds.maxX - 8 { origin.x = cursorPoint.x - Loupe.gap - side }
        if origin.y + side > bounds.maxY - 8 { origin.y = cursorPoint.y - Loupe.gap - side }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - side - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - side - 8)
        let frame = CGRect(origin: origin, size: CGSize(width: side, height: side))

        for layer in [
            loupeShadowLayer, loupeBorderLayer, loupeImageLayer, loupeGridDarkLayer,
            loupeGridLightLayer, loupeGuideLayer, loupeCellShadowLayer, loupeCellLayer,
        ] {
            layer.frame = frame
        }
        // 外框 / 投影都走 `cornerRadius`（不再描 path），转角才是 `.continuous` 的 squircle。
        loupeShadowLayer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: frame.size),
            cornerWidth: Theme.Radius.card, cornerHeight: Theme.Radius.card, transform: nil
        )

        updateLoupeReadout(frame: frame, pixel: cursorPixel)
        #if DEBUG
        loupeDebugState = DebugLoupeState(
            frame: frame,
            sourceOrigin: CGPoint(x: originX, y: originY),
            cursorPixel: cursorPixel,
            cell: CGPoint(x: cellX, y: cellY),
            cellSide: cellSide,
            hex: sampledColor?.hexString
        )
        #endif
    }

    /// 网格线固定（边长与格数都是常量），算一次就够，别每帧重建 24 条线段。
    static let loupeGridPath: CGPath = {
        let cellSide = Loupe.side / CGFloat(Loupe.cells)
        let path = CGMutablePath()
        for index in 1..<Loupe.cells {
            let offset = CGFloat(index) * cellSide
            path.move(to: CGPoint(x: offset, y: 0))
            path.addLine(to: CGPoint(x: offset, y: Loupe.side))
            path.move(to: CGPoint(x: 0, y: offset))
            path.addLine(to: CGPoint(x: Loupe.side, y: offset))
        }
        return path
    }()

    /// 读数面板：坐标 / 区域 / 色值，贴在放大镜下方（放不下就挪到上方）。
    func updateLoupeReadout(frame: CGRect, pixel: CGPoint) {
        // 只在跨过像素时才重新取样，天然节流。
        if lastSampledPixel != pixel {
            lastSampledPixel = pixel
            sampledColor = PixelSampler.sample(snapshot.image, atPixel: pixel)
        }

        let coordinate = Self.loupeReadoutRow(
            label: "坐标: ", value: String(format: "(%.0f, %.0f)", pixel.x, pixel.y)
        )
        // 「区域」= 现在按下去会截到的那块：选框 / 悬停窗口，都没有就显示占位。
        let regionPoints = selection ?? hoveredWindowLocalRect
        let region = Self.loupeReadoutRow(
            label: "区域: ",
            value: regionPoints.map {
                String(
                    format: "%.0f × %.0f",
                    ($0.width * snapshot.effectiveScale).rounded(),
                    ($0.height * snapshot.effectiveScale).rounded()
                )
            } ?? "—"
        )
        let colorRow = Self.loupeReadoutRow(
            label: "色值: ", value: sampledColor?.hexString ?? "—"
        )
        let rows = [coordinate, region, colorRow]

        let inset = Theme.Spacing.md
        let rowHeight: CGFloat = 15
        let swatchSize: CGFloat = 12
        let textWidth = rows.map(Self.loupeTextWidth).max() ?? 0
        let panelWidth = min(
            bounds.width - Theme.Spacing.md * 2,
            max(Loupe.side, textWidth + inset * 2 + swatchSize + Theme.Spacing.sm)
        )
        // 上下留白对称（原来下面靠 -4 硬凑，看着挤）。
        let panelHeight = rowHeight * CGFloat(rows.count) + inset * 2

        var panelY = frame.minY - panelHeight - Theme.Spacing.xs
        if panelY < bounds.minY + Theme.Spacing.md {
            panelY = frame.maxY + Theme.Spacing.xs
        }
        panelY = min(
            max(panelY, bounds.minY + Theme.Spacing.md),
            bounds.maxY - panelHeight - Theme.Spacing.md
        )
        let panelX = min(
            max(frame.minX, bounds.minX + Theme.Spacing.md),
            max(bounds.minX + Theme.Spacing.md, bounds.maxX - panelWidth - Theme.Spacing.md)
        )
        let panelFrame = CGRect(
            x: panelX, y: panelY, width: panelWidth, height: panelHeight
        )
        loupePanelLayer.frame = panelFrame

        let rowsTop = panelFrame.maxY - inset
        for (index, layer) in [loupeCoordinateLayer, loupeRegionLayer, loupeColorLayer]
            .enumerated()
        {
            layer.string = rows[index]
            layer.frame = CGRect(
                x: panelFrame.minX + inset,
                y: rowsTop - CGFloat(index + 1) * rowHeight,
                width: panelWidth - inset * 2,
                height: rowHeight
            )
        }

        if let sampledColor {
            loupeSwatchLayer.isHidden = false
            loupeSwatchLayer.backgroundColor = NSColor(
                srgbRed: CGFloat(sampledColor.red) / 255,
                green: CGFloat(sampledColor.green) / 255,
                blue: CGFloat(sampledColor.blue) / 255,
                alpha: 1
            ).cgColor
        } else {
            loupeSwatchLayer.isHidden = true
        }
        loupeSwatchLayer.frame = CGRect(
            x: panelFrame.minX + inset + Self.loupeTextWidth(colorRow) + Theme.Spacing.sm,
            y: rowsTop - 3 * rowHeight + (rowHeight - swatchSize) / 2,
            width: swatchSize,
            height: swatchSize
        )
        for layer in [loupeCoordinateLayer, loupeRegionLayer, loupeColorLayer, loupePanelLayer] {
            layer.isHidden = false
        }
    }

    static func loupeTextWidth(_ text: NSAttributedString) -> CGFloat {
        ceil(text.size().width)
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
        var text = String(
            format: "显示器 %d/%d  ·  %.0f×%.0f px  ·  缩放 %.2fx",
            displayIndex,
            displayCount,
            size.width,
            size.height,
            snapshot.effectiveScale
        )
        if isRecordMode && isWindowOnlyMode {
            text += "  ·  点击要录的窗口  ·  ␣ 切换自由框选  ·  Esc 取消"
        } else if isRecordMode {
            text += "  ·  拖拽框选要录的区域（或点一下某个窗口）  ·  Esc 取消"
        } else if isRegionPickMode {
            text += selection == nil
                ? "  ·  拖拽框选（鼠标停住出「手动 / 自动」）  ·  Esc 取消"
                : "  ·  鼠标停住出「手动 / 自动」，选区还能接着调  ·  Esc 取消"
        } else if isWindowOnlyMode {
            text += "  ·  点击窗口截图  ·  ␣ 切换自由框选  ·  Esc 取消"
        } else {
            text += selection == nil
                ? "  ·  拖拽框选 / 点窗口截整窗  ·  ␣ 切换窗口模式  ·  Esc 取消"
                : "  ·  ↵ 完成, ⇥ 上次选区, ⇧ 正方形  ·  Esc 取消"
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
