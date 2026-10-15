import os

/// 全 App 统一的日志入口（`os.Logger`，进系统统一日志，可在「控制台」按子系统过滤）。
///
/// 不再用 `NSLog` / `print`：它们要么不带分类与级别、要么在 Release 里根本看不到。
/// 需要新分类就在这里加一行，别在各处散写 subsystem 字符串。
///
/// @author ixxxxoooo
nonisolated enum Log {
    /// 与 Release 的 bundle id 一致；Debug 渠道也用同一个子系统，方便一条过滤条件看全。
    static let subsystem = "com.ixxxxoooo.jietu"

    /// 按分类取一个 Logger。
    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    static let app = logger("app")
    static let capture = logger("capture")
    static let overlay = logger("overlay")
    static let recording = logger("recording")
    static let scrolling = logger("scrolling")
    static let hotkeys = logger("hotkeys")
    static let ocr = logger("ocr")
    static let permissions = logger("permissions")
    static let settings = logger("settings")
    static let notifications = logger("notifications")
}
