import Carbon.HIToolbox
import Foundation
import Testing
@testable import Jietu

/// 设置的读写与默认值。
///
/// @author ixxxxoooo
@Suite("设置存储")
struct SettingsStoreTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "jietu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test("默认值符合预期")
    func defaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.copyToClipboard == true)
        #expect(store.playShutterSound == true)
        #expect(store.saveToDisk == false)
        #expect(store.showSaveNotification == true)
        #expect(store.quickAccessAutoCloseDelay == 3)
        #expect(store.saveFormat == .png)
        #expect(store.hotkeyAreaCapture == .captureArea)
    }

    @Test("每个动作都有默认热键")
    func defaultHotkeysPerAction() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        for action in HotkeyAction.allCases {
            #expect(store.hotkey(for: action) == action.defaultHotkey)
        }
        // 默认组合键两两不同，否则注册会互相顶掉。
        let combos = Set(HotkeyAction.allCases.map { store.hotkey(for: $0) })
        #expect(combos.count == HotkeyAction.allCases.count)
    }

    @Test("多个热键各自独立持久化")
    func persistsMultipleHotkeys() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        let windowKey = Hotkey(keyCode: 7, carbonModifiers: UInt32(optionKey))
        store.setHotkey(windowKey, for: .windowCapture)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.hotkey(for: .windowCapture) == windowKey)
        // 未改动的动作仍回落到默认值。
        #expect(reloaded.hotkey(for: .areaCapture) == .captureArea)
        #expect(reloaded.hotkey(for: .timedCapture) == .captureTimed)
    }

    @Test("旧版本的单热键记录会迁移到区域截图")
    func migratesLegacyHotkey() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = Hotkey(keyCode: 12, carbonModifiers: UInt32(controlKey))
        defaults.set(try JSONEncoder().encode(legacy), forKey: "hotkey.areaCapture")

        let store = SettingsStore(defaults: defaults)
        #expect(store.hotkey(for: .areaCapture) == legacy)
    }

    @Test("写入后重新读取能恢复")
    func persists() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.copyToClipboard = false
        store.saveToDisk = true
        store.hotkeyAreaCapture = Hotkey(keyCode: 5, carbonModifiers: UInt32(cmdKey))

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.copyToClipboard == false)
        #expect(reloaded.saveToDisk == true)
        #expect(reloaded.hotkeyAreaCapture.keyCode == 5)
    }

    @Test("最近截图按新到旧排序，且去重、限长")
    func recentCaptures() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        let first = URL(fileURLWithPath: "/tmp/a.png")
        let second = URL(fileURLWithPath: "/tmp/b.png")
        store.recordCapture(first)
        store.recordCapture(second)
        #expect(store.recentCaptureURLs == [second, first])

        // 重复记录应移到最前且不产生副本。
        store.recordCapture(first)
        #expect(store.recentCaptureURLs == [first, second])

        // 超出上限后只保留最近的若干条。
        for index in 0..<(SettingsStore.maxRecentCaptures + 4) {
            store.recordCapture(URL(fileURLWithPath: "/tmp/\(index).png"))
        }
        #expect(store.recentCaptureURLs.count == SettingsStore.maxRecentCaptures)

        store.clearRecentCaptures()
        #expect(store.recentCaptureURLs.isEmpty)
    }
}
