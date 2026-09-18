import AppKit

/// handle → 调整光标。用 macOS 15+ 的 `frameResize` 生成正确的斜向箭头，
/// 而不是拿 `resizeUpDown` / `resizeLeftRight` 凑合。
enum SelectionCursor {
    static func cursor(for handle: SelectionHandle) -> NSCursor {
        NSCursor.frameResize(
            position: position(for: handle),
            directions: [.inward, .outward]
        )
    }

    static func cursor(forShapeHandle handle: ShapeHandle) -> NSCursor {
        switch handle {
        case .topLeft: return cursor(for: SelectionHandle.topLeft)
        case .top: return cursor(for: SelectionHandle.top)
        case .topRight: return cursor(for: SelectionHandle.topRight)
        case .right: return cursor(for: SelectionHandle.right)
        case .bottomRight: return cursor(for: SelectionHandle.bottomRight)
        case .bottom: return cursor(for: SelectionHandle.bottom)
        case .bottomLeft: return cursor(for: SelectionHandle.bottomLeft)
        case .left: return cursor(for: SelectionHandle.left)
        case .rotate: return NSCursor.arrow
        case .arrowStart, .arrowEnd, .arrowControl, .lineStart, .lineEnd, .counterLeader:
            return NSCursor.crosshair
        }
    }

    private static func position(for handle: SelectionHandle) -> NSCursor.FrameResizePosition {
        switch handle {
        case .topLeft: return .topLeft
        case .top: return .top
        case .topRight: return .topRight
        case .right: return .right
        case .bottomRight: return .bottomRight
        case .bottom: return .bottom
        case .bottomLeft: return .bottomLeft
        case .left: return .left
        }
    }
}
