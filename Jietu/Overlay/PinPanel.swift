import AppKit

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 窗口 frame 变了（拖动 / 缩放 / 恢复实际大小）就回调一次。
    ///
    /// 光晕那层 child window 会跟着本窗口移动，但**不跟着改大小**，得靠这个通知自己同步。
    var onFrameChanged: ((NSRect) -> Void)?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        onFrameChanged?(frameRect)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        super.setFrame(frameRect, display: flag, animate: animateFlag)
        onFrameChanged?(frameRect)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        onFrameChanged?(frame)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) {
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return false
    }

    override func performClose(_ sender: Any?) {
        (contentView as? PinContentView)?.onRequestClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        (contentView as? PinContentView)?.onRequestClose?()
    }
}

/// 钉图的绘制与交互载体。
///
/// 用自绘而非 `NSImageView`：需要自己处理移动、边缘缩放与缩放，避免和系统
/// 的窗口拖拽 / 缩放行为冲突。
///
/// @author ixxxxoooo
