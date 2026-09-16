import AppKit

/// 窗口装饰（标题栏 / 工具栏等）：装到 `NSWindow` 上，与窗口同生命周期。
///
/// @author ixxxxoooo
@MainActor
protocol WindowChrome: AnyObject {
    func install(in window: NSWindow)
}
