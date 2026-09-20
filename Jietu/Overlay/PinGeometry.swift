import CoreGraphics

/// 钉图相关的几何与尺寸计算纯函数。
///
/// 保持 AppKit Local 坐标语义（原点在左下，minY 为下，maxY 为上）。
enum PinGeometry {
    static let defaultEdgeTolerance: CGFloat = 8
    static let defaultCornerTolerance: CGFloat = 12
    static let defaultMinSide: CGFloat = 60
    /// 钉图圆角。光晕那圈亮线按同一个半径画，两者才对得上。
    static let defaultCornerRadius: CGFloat = 10

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
        minSide: CGFloat = defaultMinSide
    ) -> CGRect {
        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y
        let ratio = max(0.0001, aspectRatio)
        let minW = max(minSide, minSide * ratio)
        let minH = minW / ratio

        switch handle {
        case .topRight:
            let delta = abs(dx) >= abs(dy) ? dx : (dy * ratio)
            let newW = max(minW, startFrame.width + delta)
            let newH = newW / ratio
            return CGRect(x: startFrame.minX, y: startFrame.minY, width: newW, height: newH)

        case .bottomRight:
            let delta = abs(dx) >= abs(dy) ? dx : (-dy * ratio)
            let newW = max(minW, startFrame.width + delta)
            let newH = newW / ratio
            return CGRect(x: startFrame.minX, y: startFrame.maxY - newH, width: newW, height: newH)

        case .topLeft:
            let delta = abs(dx) >= abs(dy) ? -dx : (dy * ratio)
            let newW = max(minW, startFrame.width + delta)
            let newH = newW / ratio
            return CGRect(x: startFrame.maxX - newW, y: startFrame.minY, width: newW, height: newH)

        case .bottomLeft:
            let delta = abs(dx) >= abs(dy) ? -dx : (-dy * ratio)
            let newW = max(minW, startFrame.width + delta)
            let newH = newW / ratio
            return CGRect(x: startFrame.maxX - newW, y: startFrame.maxY - newH, width: newW, height: newH)

        case .right:
            let newW = max(minW, startFrame.width + dx)
            let newH = newW / ratio
            let newY = startFrame.midY - newH / 2
            return CGRect(x: startFrame.minX, y: newY, width: newW, height: newH)

        case .left:
            let newW = max(minW, startFrame.width - dx)
            let newH = newW / ratio
            let newX = startFrame.maxX - newW
            let newY = startFrame.midY - newH / 2
            return CGRect(x: newX, y: newY, width: newW, height: newH)

        case .top:
            let newH = max(minH, startFrame.height + dy)
            let newW = newH * ratio
            let newX = startFrame.midX - newW / 2
            return CGRect(x: newX, y: startFrame.minY, width: newW, height: newH)

        case .bottom:
            let newH = max(minH, startFrame.height - dy)
            let newW = newH * ratio
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
        minSide: CGFloat = defaultMinSide,
        maxSize: CGSize = CGSize(width: 8000, height: 8000)
    ) -> CGRect {
        guard currentFrame.width > 0, currentFrame.height > 0 else { return currentFrame }
        let ratio = max(0.0001, aspectRatio)

        // 归一化焦点比例（0...1，原点左下角）
        let unitX = max(0.0, min(1.0, mouseLocationInWindow.x / currentFrame.width))
        let unitY = max(0.0, min(1.0, mouseLocationInWindow.y / currentFrame.height))

        // 鼠标在屏幕坐标系中的锚点
        let mouseScreenX = currentFrame.minX + unitX * currentFrame.width
        let mouseScreenY = currentFrame.minY + unitY * currentFrame.height

        let minW = max(minSide, minSide * ratio)
        let maxW = min(maxSize.width, maxSize.height * ratio)

        let targetWidth = currentFrame.width * factor
        let clampedWidth = max(minW, min(maxW, targetWidth))
        let clampedHeight = clampedWidth / ratio

        let newOriginX = mouseScreenX - unitX * clampedWidth
        let newOriginY = mouseScreenY - unitY * clampedHeight

        return CGRect(x: newOriginX, y: newOriginY, width: clampedWidth, height: clampedHeight)
    }
}
