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
