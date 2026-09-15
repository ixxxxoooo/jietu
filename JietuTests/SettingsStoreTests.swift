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
        #expect(store.quickAccessAutoCloseDelay == 3)
        #expect(store.saveFormat == .png)
        #expect(store.hotkeyAreaCapture == .captureArea)
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
