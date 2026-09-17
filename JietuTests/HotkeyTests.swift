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
        let hotkey = Hotkey(
            keyCode: UInt32(kVK_ANSI_A),
            carbonModifiers: UInt32(cmdKey | shiftKey)
        )
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
        // 菜单要拿它当 keyEquivalent：录制时按的字符（不含修饰键）一并存下来。
        #expect(hotkey.menuKeyEquivalent == "a")
        #expect(hotkey.cocoaModifiers == [.command, .shift])
    }

    @Test("老热键（没有存下字符）也能推出菜单要显示的那个键")
    func menuKeyFallsBackToKeyCode() {
        // 用户机器上那条真实数据：keyCode 0 = A、⌘⇧（没有 menuKeyEquivalent 字段）。
        let legacy = Hotkey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey | shiftKey))
        #expect(legacy.menuKey == "a")
        #expect(legacy.cocoaModifiers == [.command, .shift])

        // 数字 / 标点 / 功能键 / 方向键也能推。
        #expect(Hotkey(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(cmdKey)).menuKey == "3")
        #expect(Hotkey(keyCode: UInt32(kVK_ANSI_Slash), carbonModifiers: UInt32(cmdKey)).menuKey == "/")
        let f1 = Hotkey(keyCode: UInt32(kVK_F1), carbonModifiers: UInt32(cmdKey)).menuKey
        #expect(f1 == String(Character(UnicodeScalar(0xF704)!)), "F1 用 AppKit 那个私有区字符")
        let up = Hotkey(keyCode: UInt32(kVK_UpArrow), carbonModifiers: UInt32(cmdKey)).menuKey
        #expect(up == String(Character(UnicodeScalar(0xF700)!)))

        // 录制时存下的字符优先（非美式键盘上它才准）。
        let typed = Hotkey(
            keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey), menuKeyEquivalent: "q"
        )
        #expect(typed.menuKey == "q")
    }

    @Test("老数据（没有 menuKeyEquivalent 字段）照样能解码")
    func decodesLegacyHotkeyWithoutMenuKey() throws {
        let json = #"{"keyCode":15,"carbonModifiers":\#(UInt32(cmdKey | shiftKey))}"#
        let hotkey = try JSONDecoder().decode(Hotkey.self, from: Data(json.utf8))
        #expect(hotkey.keyCode == UInt32(kVK_ANSI_R))
        #expect(hotkey.menuKeyEquivalent == nil, "老数据没有这一项：菜单里就不显示快捷键")
    }
}
