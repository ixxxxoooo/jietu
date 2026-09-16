import AppKit

/// 定位「系统设置」的窗口，用来把拖拽授权面板贴在它下面。
///
/// 用 `CGWindowList` + owner pid 反查 bundle id：
/// 既**不需要辅助功能权限**（PermissionFlow 那条路是 AX 观察，得多要一个权限），
/// 也不受系统语言影响（窗口标题是本地化的，bundle id 不是）。
///
/// @author ixxxxoooo
enum SystemSettingsWindow {
    private static let bundleIdentifier = "com.apple.systempreferences"

    /// 系统设置左侧栏宽度：面板只贴右侧内容区，才和用户正在操作的那一栏对齐。
    static let sidebarWidth: CGFloat = 230

    /// 系统设置当前窗口的 frame（cg 全局坐标：原点主屏左上、Y 向下）。
    ///
    /// 太窄的窗口（比如某个 sheet）不算。
    static func frameInCGPoints() -> CGRect? {
        guard
            let pid = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { !$0.isTerminated })?
                .processIdentifier
        else { return nil }

        return WindowHitTester.onScreenWindows(excludingPID: getpid())
            .first { $0.ownerPID == pid && $0.frameInCGPoints.width >= 400 }?
            .frameInCGPoints
    }

    /// cg 矩形 → AppKit 屏幕坐标（原点主屏左下），面板定位要用。
    static func appKitFrame(fromCG rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: DisplayGeometry.referenceHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
