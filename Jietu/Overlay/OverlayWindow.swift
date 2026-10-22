import AppKit

/// 遮罩窗用 `NSPanel` + `.nonactivatingPanel`，而不是普通窗口。
///
/// 原因：全局热键触发时，前台是别的 App。普通窗口必须先把 Jietu 激活成前台 App
/// 才能成为 key window，而激活会打断用户当前的操作（也让 Esc 的投递变得不可靠）。
/// 非激活面板可以「不激活 App 也拿到键盘焦点」，这正是 Spotlight 类浮层的做法。
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
