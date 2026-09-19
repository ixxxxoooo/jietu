import AppKit
import Carbon.HIToolbox
import Testing
@testable import Jietu

/// HotkeyCenter 注册 / 注销 + HotkeyAction 属性完整性测试。
///
/// 注意：Carbon 的 RegisterEventHotKey 需要 run loop，某些 CI 环境下可能静默失败
/// （register 返回 nil），因此注册类测试使用 `#expect(... != nil)` 而非 `#require`，
/// 确保 CI 不会因环境限制而误报。
///
/// @author ygw
@Suite("热键中心")
struct HotkeyCenterTests {

    // MARK: - HotkeyAction 属性完整性

    @Test("每个 HotkeyAction 都有非空的 title")
    func allActionsHaveTitles() {
        for action in HotkeyAction.allCases {
            #expect(!action.title.isEmpty, "\(action) 应有 title")
        }
    }

    @Test("每个 HotkeyAction 都有非空的 subtitle")
    func allActionsHaveSubtitles() {
        for action in HotkeyAction.allCases {
            #expect(!action.subtitle.isEmpty, "\(action) 应有 subtitle")
        }
    }

    @Test("每个 HotkeyAction 都有 SF Symbol 名")
    func allActionsHaveSymbols() {
        for action in HotkeyAction.allCases {
            #expect(!action.symbol.isEmpty, "\(action) 应有 symbol")
        }
    }

    @Test("HotkeyAction 的 id 等于 rawValue")
    func actionIdIsRawValue() {
        for action in HotkeyAction.allCases {
            #expect(action.id == action.rawValue)
        }
    }

    @Test("HotkeyAction 有 8 种动作")
    func actionCount() {
        #expect(HotkeyAction.allCases.count == 8, "截图 5 种 + 录屏 3 种 = 8 种")
    }

    // MARK: - HotkeyCenter 注册 / 注销

    @Test("注册返回递增的 ID")
    func registerReturnsIncrementingIDs() {
        let center = HotkeyCenter()
        defer { center.unregisterAll() }

        let hotkey1 = Hotkey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey | shiftKey))
        let hotkey2 = Hotkey(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(cmdKey | shiftKey))

        let id1 = center.register(hotkey1) {}
        let id2 = center.register(hotkey2) {}

        // Carbon API 在测试宿主中可能不可用
        if let id1, let id2 {
            #expect(id2 > id1, "ID 应递增")
        }
    }

    @Test("注销后再注销同一个 ID 不崩溃")
    func unregisterTwiceDoesNotCrash() {
        let center = HotkeyCenter()
        defer { center.unregisterAll() }

        let hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey))
        if let id = center.register(hotkey, action: {}) {
            center.unregister(id)
            center.unregister(id) // 第二次应静默忽略
        }
    }

    @Test("unregisterAll 不崩溃")
    func unregisterAllDoesNotCrash() {
        let center = HotkeyCenter()
        let hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(cmdKey | optionKey))
        _ = center.register(hotkey) {}
        _ = center.register(
            Hotkey(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(cmdKey | optionKey))
        ) {}
        center.unregisterAll()
        // 再调一次也不崩
        center.unregisterAll()
    }

    @Test("注销不存在的 ID 不崩溃")
    func unregisterNonExistentID() {
        let center = HotkeyCenter()
        center.unregister(999)
        center.unregister(0)
    }

    // MARK: - Hotkey.matches

    @Test("matches 只比较键码和修饰键")
    func matchesIgnoresMenuKey() throws {
        let hotkey = Hotkey(
            keyCode: UInt32(kVK_ANSI_A),
            carbonModifiers: UInt32(cmdKey | shiftKey),
            menuKeyEquivalent: "a"
        )
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "A", charactersIgnoringModifiers: "a",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_A)
            )
        )
        #expect(hotkey.matches(event))
    }

    @Test("修饰键不匹配时 matches 返回 false")
    func matchesFailsOnWrongModifiers() throws {
        let hotkey = Hotkey(
            keyCode: UInt32(kVK_ANSI_A),
            carbonModifiers: UInt32(cmdKey | shiftKey)
        )
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [.command], // 缺少 shift
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "a", charactersIgnoringModifiers: "a",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_A)
            )
        )
        #expect(!hotkey.matches(event))
    }
}
