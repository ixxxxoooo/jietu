import AppKit
import Carbon.HIToolbox
import Testing
@testable import Jietu

/// 热键的显示串与从键盘事件解析组合键。
///
/// @author ixxxxoooo
@Suite("热键")
struct HotkeyTests {
    @Test("修饰键符号顺序为 ⌃⌥⇧⌘")
    func displayString() {
        let hotkey = Hotkey.captureArea
        #expect(hotkey.displayString == "⇧⌘A")
    }

    @Test("没有修饰键时拒绝录入")
    func fromEventRequiresModifier() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_A)
            )
        )
        #expect(Hotkey.from(event: event) == nil)
    }

    @Test("⌘⇧A 解析为对应 keyCode 与修饰位")
    func fromEventParsesCombo() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "A",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_A)
            )
        )
        let hotkey = try #require(Hotkey.from(event: event))
        #expect(hotkey.keyCode == UInt32(kVK_ANSI_A))
        #expect(hotkey.carbonModifiers == UInt32(cmdKey | shiftKey))
    }
}
