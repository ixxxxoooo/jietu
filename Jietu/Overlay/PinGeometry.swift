import CoreGraphics

/// 钉图相关的几何与尺寸计算纯函数。
///
/// 保持 AppKit Local 坐标语义（原点在左下，minY 为下，maxY 为上）。
///
/// 钉图窗口 = 卡片外框，里面那圈才是截图本身（见 `PreviewCard`）。窗口尺寸与截图尺寸
/// 差 `contentInset * 2`，所以所有「锁宽高比」的算式都作用在**内容**上，
/// 由 `contentInset` 在两头换算——不传就是老口径（窗口即截图）。
enum PinGeometry {
    static let defaultEdgeTolerance: CGFloat = 8
    static let defaultCornerTolerance: CGFloat = 12
    static let defaultMinSide: CGFloat = 60

    /// 截图在窗口里的矩形（原点左下）。`inset` 为 0 时就是窗口本身。
    static func contentRect(of frame: CGRect, inset: CGFloat) -> CGRect {
        inset > 0 ? frame.insetBy(dx: inset, dy: inset) : frame
    }

    /// 检测鼠标在视图内命中的调整手柄（8 向）。
    static func handle(
        at point: CGPoint,
        in bounds: CGRect,
        edgeTolerance: CGFloat = defaultEdgeTolerance,
        cornerTolerance: CGFloat = defaultCornerTolerance
    ) -> SelectionHandle? {
        guard bounds.contains(point),
              bounds.width > cornerTolerance * 2,
              bounds.height > cornerTolerance * 2 else {
            return nil
        }

        let isCornerLeft = point.x <= cornerTolerance
        let isCornerRight = point.x >= bounds.width - cornerTolerance
        let isCornerBottom = point.y <= cornerTolerance
        let isCornerTop = point.y >= bounds.height - cornerTolerance

        if isCornerLeft && isCornerTop { return .topLeft }
        if isCornerRight && isCornerTop { return .topRight }
        if isCornerLeft && isCornerBottom { return .bottomLeft }
        if isCornerRight && isCornerBottom { return .bottomRight }

        let isNearLeft = point.x <= edgeTolerance
        let isNearRight = point.x >= bounds.width - edgeTolerance
        let isNearBottom = point.y <= edgeTolerance
        let isNearTop = point.y >= bounds.height - edgeTolerance

        if isNearLeft { return .left }
        if isNearRight { return .right }
        if isNearTop { return .top }
        if isNearBottom { return .bottom }

        return nil
    }

    /// 拖拽手柄调整大小（锁定宽高比，防画面变形）。
    ///
    /// - 四角调整：对角作为不动锚点，当前拖拽角朝鼠标方向扩展/收缩。
    /// - 四边调整：对边所在轴向固定，垂直轴向从中心向两侧对称扩展。
    static func resizedFrame(
        startFrame: CGRect,
        handle: SelectionHandle,
        startMouse: CGPoint,
        currentMouse: CGPoint,
        aspectRatio: CGFloat,
        contentInset: CGFloat = 0,
        minSide: CGFloat = defaultMinSide
    ) -> CGRect {
        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y
        let ratio = max(0.0001, aspectRatio)
        let padding = contentInset * 2

        /// 窗口尺寸 ↔ 内容尺寸：内容那一圈才是锁比例的那块。
        func height(forWidth width: CGFloat) -> CGFloat {
            max(1, width - padding) / ratio + padding
        }
        func width(forHeight height: CGFloat) -> CGFloat {
            max(1, height - padding) * ratio + padding
        }

        let minW = max(minSide, minSide * ratio) + padding
        let minH = max(minSide, minSide * ratio) / ratio + padding

        switch handle {
        case .topRight:
            let delta = abs(dx) >= abs(dy) ? dx : (dy * ratio)
            let newW = max(minW, startFrame.width + delta)
            let newH = height(forWidth: newW)
            return CGRect(x: startFrame.minX, y: startFrame.minY, width: newW, height: newH)

        case .bottomRight:
            let delta = abs(dx) >= abs(dy) ? dx : (-dy * ratio)
            let newW = max(minW, startFrame.width + delta)
            let newH = height(forWidth: newW)
            return CGRect(x: startFrame.minX, y: startFrame.maxY - newH, width: newW, height: newH)

        case .topLeft:
            let delta = abs(dx) >= abs(dy) ? -dx : (dy * ratio)
            let newW = max(minW, startFrame.width + delta)
            let newH = height(forWidth: newW)
            return CGRect(x: startFrame.maxX - newW, y: startFrame.minY, width: newW, height: newH)

        case .bottomLeft:
            let delta = abs(dx) >= abs(dy) ? -dx : (-dy * ratio)
            let newW = max(minW, startFrame.width + delta)
            let newH = height(forWidth: newW)
            return CGRect(x: startFrame.maxX - newW, y: startFrame.maxY - newH, width: newW, height: newH)

        case .right:
            let newW = max(minW, startFrame.width + dx)
            let newH = height(forWidth: newW)
            let newY = startFrame.midY - newH / 2
            return CGRect(x: startFrame.minX, y: newY, width: newW, height: newH)

        case .left:
            let newW = max(minW, startFrame.width - dx)
            let newH = height(forWidth: newW)
            let newX = startFrame.maxX - newW
            let newY = startFrame.midY - newH / 2
            return CGRect(x: newX, y: newY, width: newW, height: newH)

        case .top:
            let newH = max(minH, startFrame.height + dy)
            let newW = width(forHeight: newH)
            let newX = startFrame.midX - newW / 2
            return CGRect(x: newX, y: startFrame.minY, width: newW, height: newH)

        case .bottom:
            let newH = max(minH, startFrame.height - dy)
            let newW = width(forHeight: newH)
            let newX = startFrame.midX - newW / 2
            let newY = startFrame.maxY - newH
            return CGRect(x: newX, y: newY, width: newW, height: newH)
        }
    }

    /// 以鼠标指针在窗口中的位置为焦点进行等比缩放（滚轮 / 触控板捏合）。
    ///
    /// 缩放前后，鼠标指针下方对应的图像像素位置保持严格对齐，不会出现焦点漂移。
    static func zoomedFrame(
        currentFrame: CGRect,
        factor: CGFloat,
        mouseLocationInWindow: CGPoint,
        aspectRatio: CGFloat,
        contentInset: CGFloat = 0,
        minSide: CGFloat = defaultMinSide,
        maxSize: CGSize = CGSize(width: 8000, height: 8000)
    ) -> CGRect {
        guard currentFrame.width > 0, currentFrame.height > 0 else { return currentFrame }
        let ratio = max(0.0001, aspectRatio)
        let padding = contentInset * 2

        // 缩放作用在**截图**上：先换到内容矩形，算完再包回外框。
        let content = contentRect(of: currentFrame, inset: contentInset)
        guard content.width > 0, content.height > 0 else { return currentFrame }

        // 归一化焦点比例（0...1，原点左下角）。鼠标压在边框上时夹到边上。
        let unitX = max(0.0, min(1.0, (mouseLocationInWindow.x - contentInset) / content.width))
        let unitY = max(0.0, min(1.0, (mouseLocationInWindow.y - contentInset) / content.height))

        // 鼠标在屏幕坐标系中的锚点
        let mouseScreenX = content.minX + unitX * content.width
        let mouseScreenY = content.minY + unitY * content.height

        let minW = max(minSide, minSide * ratio)
        let maxW = min(maxSize.width, maxSize.height * ratio)

        let targetWidth = content.width * factor
        let clampedWidth = max(minW, min(maxW, targetWidth))
        let clampedHeight = clampedWidth / ratio

        let newOriginX = mouseScreenX - unitX * clampedWidth - contentInset
        let newOriginY = mouseScreenY - unitY * clampedHeight - contentInset

        return CGRect(
            x: newOriginX,
            y: newOriginY,
            width: clampedWidth + padding,
            height: clampedHeight + padding
        )
    }
}
