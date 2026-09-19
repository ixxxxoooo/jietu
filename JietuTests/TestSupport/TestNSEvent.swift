import AppKit

/// 测试用的合成鼠标事件工厂。
///
/// @author ygw
enum TestNSEvent {
    /// 合成一个鼠标事件，用于测试 hit testing 和拖拽逻辑。
    static func mouse(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
    }
}
