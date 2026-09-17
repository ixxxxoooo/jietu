import AppKit
import Carbon.HIToolbox

struct Hotkey: Codable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// 录制那次按下的**字符**（`charactersIgnoringModifiers`）：菜单项要拿它当 `keyEquivalent`
    /// 才能把快捷键显示出来。功能键 / 方向键在这里也是一个个 Unicode 字符（F1 = U+F704），
    /// 正好是 AppKit 认的那套，不用再维护一张键码表。
    ///
    /// 可选：老数据（这个字段之前就存下来的）没有它，解码成 nil，菜单里就只显示不出来。
    var menuKeyEquivalent: String?
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

    /// 逐个按键符号，设置页的录制器按芯片逐个排。
    var keycaps: [String] {
        modifierSymbols.map(String.init) + [keySymbol]
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
        // 只认「一个字符」的那种键：菜单的 keyEquivalent 也只能是一个字符。
        let typed = event.charactersIgnoringModifiers
        let menuKey = (typed?.count == 1) ? typed : nil
        return Hotkey(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbon,
            menuKeyEquivalent: menuKey
        )
    }

    /// 菜单项要用的那个字符：**录制时存下的优先**（非美式键盘上它才准——同一个键码在不同布局上
    /// 打出来的是不同的字），老数据（这个字段之前录的）没有就按键码推。
    var menuKey: String? {
        if let menuKeyEquivalent, !menuKeyEquivalent.isEmpty { return menuKeyEquivalent }
        return Self.menuKey(forKeyCode: keyCode)
    }

    /// 键码 → 菜单 `keyEquivalent` 用的字符。
    ///
    /// - 字母 / 数字 / 标点：`keyNames` 里那份（显示用是大写，菜单用小写，AppKit 会按 Shift 自动大写）；
    /// - 功能键 / 方向键：AppKit 那套 `NSxxxFunctionKey`（0xF700 起）——它们本来就是一个个字符。
    static func menuKey(forKeyCode keyCode: UInt32) -> String? {
        if let special = specialKeyCharacters[Int(keyCode)] { return special }
        guard let name = keyNames[Int(keyCode)], name.count == 1 else { return nil }
        return name.lowercased()
    }

    private static let specialKeyCharacters: [Int: String] = [
        kVK_Return: "\r",
        kVK_Tab: "\t",
        kVK_Space: " ",
        kVK_Delete: "\u{8}",
        kVK_Escape: "\u{1B}",
        kVK_ForwardDelete: scalar(0xF728),
        kVK_LeftArrow: scalar(0xF702),
        kVK_RightArrow: scalar(0xF703),
        kVK_UpArrow: scalar(0xF700),
        kVK_DownArrow: scalar(0xF701),
        kVK_Home: scalar(0xF729),
        kVK_End: scalar(0xF72B),
        kVK_PageUp: scalar(0xF72C),
        kVK_PageDown: scalar(0xF72D),
        kVK_F1: scalar(0xF704), kVK_F2: scalar(0xF705), kVK_F3: scalar(0xF706),
        kVK_F4: scalar(0xF707), kVK_F5: scalar(0xF708), kVK_F6: scalar(0xF709),
        kVK_F7: scalar(0xF70A), kVK_F8: scalar(0xF70B), kVK_F9: scalar(0xF70C),
        kVK_F10: scalar(0xF70D), kVK_F11: scalar(0xF70E), kVK_F12: scalar(0xF70F),
    ]

    private static func scalar(_ value: UInt32) -> String {
        guard let scalar = UnicodeScalar(value) else { return "" }
        return String(Character(scalar))
    }

    /// 菜单项要用的修饰键掩码（Carbon → Cocoa）。
    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
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
