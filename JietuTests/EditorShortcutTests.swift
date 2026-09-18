import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Jietu

/// 标注编辑器内部的撤销 / 重做快捷键。
///
/// @author ixxxxoooo
@Suite("标注编辑快捷键")
struct EditorShortcutTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "jietu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func keyEvent(
        _ keyCode: Int,
        _ flags: NSEvent.ModifierFlags,
        characters: String
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters.lowercased(),
                isARepeat: false,
                keyCode: UInt16(keyCode)
            )
        )
    }

    @Test("出厂默认：⌘Z 撤销、⇧⌘Z 重做")
    func standardDefaults() {
        let shortcuts = EditorShortcuts.standard
        #expect(shortcuts.undo?.displayString == "⌘Z")
        #expect(shortcuts.redo?.displayString == "⇧⌘Z")
        #expect(shortcuts.undo == EditorShortcut.undo.defaultHotkey)
        #expect(shortcuts.redo == EditorShortcut.redo.defaultHotkey)
    }

    @Test("两条默认都指着 Z")
    func defaultsShareTheZKey() {
        #expect(EditorShortcut.undo.defaultHotkey.keyCode == UInt32(kVK_ANSI_Z))
        #expect(EditorShortcut.redo.defaultHotkey.keyCode == UInt32(kVK_ANSI_Z))
        #expect(EditorShortcut.undo.defaultHotkey.carbonModifiers == UInt32(cmdKey))
        #expect(EditorShortcut.redo.defaultHotkey.carbonModifiers == UInt32(cmdKey | shiftKey))
    }

    @Test("按键匹配：⌘Z 命中撤销且不命中重做")
    func matchesUndoEvent() throws {
        let undo = try keyEvent(kVK_ANSI_Z, [.command], characters: "z")
        let redo = try keyEvent(kVK_ANSI_Z, [.command, .shift], characters: "Z")
        let shortcuts = EditorShortcuts.standard

        #expect(shortcuts.undo?.matches(undo) == true)
        #expect(shortcuts.undo?.matches(redo) == false)
        #expect(shortcuts.redo?.matches(redo) == true)
        #expect(shortcuts.redo?.matches(undo) == false)
    }

    @Test("按键匹配只看键码与修饰键，不看事件里的字符")
    func matchesIgnoresCharacters() throws {
        // 非美式键盘布局下同一个键码打出来的是别的字；这条不该影响命中。
        let event = try keyEvent(kVK_ANSI_Z, [.command], characters: "w")
        #expect(EditorShortcuts.standard.undo?.matches(event) == true)
    }

    @Test("解绑后不匹配任何按键")
    func unboundMatchesNothing() throws {
        var shortcuts = EditorShortcuts.standard
        shortcuts.set(nil, for: .undo)
        let event = try keyEvent(kVK_ANSI_Z, [.command], characters: "z")
        #expect(shortcuts.undo == nil)
        #expect(shortcuts.hotkey(for: .undo) == nil)
        #expect(shortcuts.redo?.matches(event) == false)
    }

    @Test("设置存储：首次启动就带着默认绑定，而不是空的")
    func storeStartsWithDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.editorShortcuts == .standard)
        #expect(store.editorShortcuts.hotkey(for: .undo)?.displayString == "⌘Z")
        #expect(store.editorShortcuts.hotkey(for: .redo)?.displayString == "⇧⌘Z")
    }

    @Test("设置存储：改过之后重开还是改过的值，另一条保持默认")
    func storePersistsOverride() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let custom = Hotkey(
            keyCode: UInt32(kVK_ANSI_Y),
            carbonModifiers: UInt32(cmdKey),
            menuKeyEquivalent: "y"
        )
        let store = SettingsStore(defaults: defaults)
        var shortcuts = store.editorShortcuts
        shortcuts.set(custom, for: .redo)
        store.editorShortcuts = shortcuts

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.editorShortcuts.hotkey(for: .redo) == custom)
        #expect(reopened.editorShortcuts.hotkey(for: .undo) == EditorShortcut.undo.defaultHotkey)
    }

    @Test("设置存储：解绑是显式状态，不会被默认值填回来")
    func storeKeepsExplicitUnbind() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        var shortcuts = store.editorShortcuts
        shortcuts.set(nil, for: .undo)
        store.editorShortcuts = shortcuts

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.editorShortcuts.hotkey(for: .undo) == nil)
        #expect(reopened.editorShortcuts.hotkey(for: .redo) == EditorShortcut.redo.defaultHotkey)
    }

    @Test("恢复默认把两条一起还原")
    func resetRestoresStandard() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        var shortcuts = store.editorShortcuts
        shortcuts.set(nil, for: .undo)
        shortcuts.set(nil, for: .redo)
        store.editorShortcuts = shortcuts
        #expect(store.editorShortcuts != .standard)

        store.resetEditorShortcuts()
        #expect(store.editorShortcuts == .standard)
        #expect(SettingsStore(defaults: defaults).editorShortcuts == .standard)
    }
}
