import CoreGraphics

/// 选区的 8 个调整点。
///
/// 坐标语义全部按 AppKit local（原点左下）：`minY` 是下边、`maxY` 是上边。
enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var affectsMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var affectsMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
    var affectsMinY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var affectsMaxY: Bool { self == .topLeft || self == .top || self == .topRight }

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: return true
        case .top, .right, .bottom, .left: return false
        }
    }

    func center(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

enum SelectionGeometry {
    /// 小于这个尺寸就不算一次有效框选，退回到「点击」语义。
    static let minimumSide: CGFloat = 4

    /// 拖拽框选：由锚点和当前点得到一个规范化矩形。
    static func rect(from anchor: CGPoint, to point: CGPoint) -> CGRect {
        CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
    }

    /// 框选用的矩形。`square` 为真时锁成正方形（按住 Shift），锚点固定不动。
    static func selectionRect(
        from anchor: CGPoint,
        to point: CGPoint,
        clampTo bounds: CGRect,
        square: Bool
    ) -> CGRect {
        var dx = point.x - anchor.x
        var dy = point.y - anchor.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return rect(from: anchor, to: CGPoint(x: anchor.x + dx, y: anchor.y + dy))
            .intersection(bounds)
    }

    /// 调整某个 handle 后得到的新矩形。
    ///
    /// - `lockAspect` 时按原始宽高比换算，只对四角生效（边上拖拽锁比例没有意义）
    /// - 结果始终被裁进 `bounds`，并且各边不小于 `minimumSide`
    static func resized(
        _ original: CGRect,
        handle: SelectionHandle,
        to point: CGPoint,
        clampTo bounds: CGRect,
        lockAspect: Bool
    ) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        if handle.affectsMinX { minX = point.x }
        if handle.affectsMaxX { maxX = point.x }
        if handle.affectsMinY { minY = point.y }
        if handle.affectsMaxY { maxY = point.y }

        // 反向拖过对边时不做镜像，直接交换，避免选区「翻面」后抖动。
        if maxX < minX { swap(&minX, &maxX) }
        if maxY < minY { swap(&minY, &maxY) }

        minX = max(minX, bounds.minX)
        minY = max(minY, bounds.minY)
        maxX = min(maxX, bounds.maxX)
        maxY = min(maxY, bounds.maxY)

        if lockAspect, handle.isCorner, original.height > 0 {
            let ratio = original.width / original.height
            var width = max(maxX - minX, minimumSide)
            var height = max(maxY - minY, minimumSide)
            if width / height > ratio {
                width = height * ratio
            } else {
                height = width / ratio
            }
            // 对角固定不动，向被拖的角伸展。
            if handle.affectsMinX { minX = maxX - width } else { maxX = minX + width }
            if handle.affectsMinY { minY = maxY - height } else { maxY = minY + height }

            // 比例换算可能又把矩形推出边界，这里回推而不是简单裁剪。
            if minX < bounds.minX {
                minX = bounds.minX
                maxX = minX + width
            }
            if maxX > bounds.maxX {
                maxX = bounds.maxX
                minX = maxX - width
            }
            if minY < bounds.minY {
                minY = bounds.minY
                maxY = minY + height
            }
            if maxY > bounds.maxY {
                maxY = bounds.maxY
                minY = maxY - height
            }
        } else {
            if maxX - minX < minimumSide { maxX = minX + minimumSide }
            if maxY - minY < minimumSide { maxY = minY + minimumSide }
            maxX = min(maxX, bounds.maxX)
            maxY = min(maxY, bounds.maxY)
            minX = max(minX, bounds.minX)
            minY = max(minY, bounds.minY)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 平移选区并裁进边界。
    static func moved(_ original: CGRect, by delta: CGSize, clampTo bounds: CGRect) -> CGRect {
        var rect = original.offsetBy(dx: delta.width, dy: delta.height)
        rect.origin.x = min(max(rect.origin.x, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.origin.y, bounds.minY), bounds.maxY - rect.height)
        return rect
    }

    /// 命中哪个 handle。`tolerance` 是判定半径（point）。
    static func handle(
        at point: CGPoint,
        in rect: CGRect,
        tolerance: CGFloat
    ) -> SelectionHandle? {
        SelectionHandle.allCases.first { handle in
            let center = handle.center(in: rect)
            return abs(point.x - center.x) <= tolerance
                && abs(point.y - center.y) <= tolerance
        }
    }
}
