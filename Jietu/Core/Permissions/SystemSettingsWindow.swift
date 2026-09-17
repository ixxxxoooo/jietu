import AppKit

/// 定位「系统设置」的窗口，用来把拖拽授权面板贴在它下面、并跟它同层排序。
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

    /// 面板要贴的那个窗口：位置用于定位，windowNumber / level 用于**排序**。
    ///
    /// 光有 frame 不够：面板得排在这个窗口的正上方、并且跟它同一层级，
    /// 否则别的窗口盖住系统设置时，面板还会浮在那些窗口前面。
    struct Target {
        /// AppKit 屏幕坐标（原点主屏左下）。
        let appKitFrame: CGRect
        let windowNumber: CGWindowID
        /// 系统设置窗口的层级，正常就是普通窗口层（0）。
        let level: Int
    }

    /// 系统设置当前窗口（含定位与层级信息）。
    ///
    /// 太窄的窗口（比如某个 sheet）不算。
    static func target() -> Target? {
        guard
            let pid = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { !$0.isTerminated })?
                .processIdentifier
        else { return nil }

        guard
            let window = WindowHitTester.onScreenWindows(excludingPID: getpid())
                .first(where: { $0.ownerPID == pid && $0.frameInCGPoints.width >= 400 })
        else { return nil }

        return Target(
            appKitFrame: appKitFrame(fromCG: window.frameInCGPoints),
            windowNumber: window.windowID,
            level: window.layer
        )
    }

    /// 把系统设置拉到前台。
    ///
    /// 光靠 settings URL 不够：**已经停在那一栏时它是个 no-op**，窗口不会前置，
    /// 面板上的「设置」按钮看起来就像坏了。
    @discardableResult
    static func activate() -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { !$0.isTerminated }?
            .activate() ?? false
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
