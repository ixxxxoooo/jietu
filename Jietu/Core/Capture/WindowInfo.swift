import AppKit
import CoreGraphics

/// 一个可被吸附的窗口。
struct WindowInfo {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    /// 窗口层级（`kCGWindowLayer`，普通窗口是 0）。窗口排序要先对齐层级才生效。
    let layer: Int
    /// cg 全局坐标（原点主屏左上，单位 point）。
    let frameInCGPoints: CGRect

    var displayName: String {
        title.isEmpty ? ownerName : title
    }
}

enum WindowHitTester {
    /// 当前屏幕上的普通窗口，**按前后顺序排列**（索引 0 最靠前）。
    ///
    /// 用 `CGWindowListCopyWindowInfo` 而不是 `SCShareableContent.windows`：
    /// 前者保证按 z-order 返回，吸附命中要靠这个顺序；后者没有顺序保证。
    static func onScreenWindows(excludingPID excludedPID: pid_t) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        return raw.compactMap { entry in
            let layer = entry[kCGWindowLayer as String] as? Int ?? -1
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 0
            let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32 ?? -1

            // 只要普通窗口与面板层级（0...25），且不是自己（遮罩窗不能参与吸附）。
            guard layer >= 0 && layer <= 25, alpha > 0.01, ownerPID != excludedPID else { return nil }
            // 直接取字段而不是 CGRect(dictionaryRepresentation:)，避开 CFDictionary 桥接告警。
            guard let bounds = entry[kCGWindowBounds as String] as? [String: NSNumber] else {
                return nil
            }
            let frame = CGRect(
                x: bounds["X"]?.doubleValue ?? 0,
                y: bounds["Y"]?.doubleValue ?? 0,
                width: bounds["Width"]?.doubleValue ?? 0,
                height: bounds["Height"]?.doubleValue ?? 0
            )
            // 太小的（提示气泡、tooltip）不值得吸附。
            guard frame.width >= 48, frame.height >= 48 else { return nil }

            return WindowInfo(
                windowID: entry[kCGWindowNumber as String] as? CGWindowID ?? 0,
                ownerPID: ownerPID,
                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                title: entry[kCGWindowName as String] as? String ?? "",
                layer: layer,
                frameInCGPoints: frame
            )
        }
    }

    /// 命中鼠标下最靠前的窗口（列表已按 z-order 排好）。
    static func frontmost(atCGPoint point: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.frameInCGPoints.contains(point) }
    }
}
