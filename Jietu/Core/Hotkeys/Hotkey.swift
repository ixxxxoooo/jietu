import AppKit
import Carbon.HIToolbox

struct Hotkey: Codable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let captureArea = Hotkey(
        keyCode: UInt32(kVK_ANSI_A),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    static let captureWindow = Hotkey(
        keyCode: UInt32(kVK_ANSI_W),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    static let captureFullScreen = Hotkey(
        keyCode: UInt32(kVK_ANSI_F),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    static let captureTimed = Hotkey(
        keyCode: UInt32(kVK_ANSI_T),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    static let captureScrolling = Hotkey(
        keyCode: UInt32(kVK_ANSI_L),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    /// 空格：截图后「未做任何操作」时，唤回最近一张浮窗。
    ///
    /// 只在很短的时间窗内注册，避免长期占用系统空格键。
    static let recallLastCapture = Hotkey(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: 0
    )
}

extension Hotkey {
    var modifierSymbols: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    var keySymbol: String {
        Hotkey.keyNames[Int(keyCode)] ?? "?"
    }

    var displayString: String {
        modifierSymbols + keySymbol
    }

    /// 从一次本地键盘事件构造热键；用于设置页录制组合键。
    static func from(event: NSEvent) -> Hotkey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        // 至少需要一个修饰键，否则会吞掉正常输入。
        guard carbon != 0 else { return nil }
        return Hotkey(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "␣", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
