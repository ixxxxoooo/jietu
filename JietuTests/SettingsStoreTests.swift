import Carbon.HIToolbox
import Foundation
import Testing
@testable import Jietu

/// 设置的读写与默认值。
///
/// @author ixxxxoooo
@Suite("设置存储")
struct SettingsStoreTests {
    @Test("默认值符合预期")
    func defaults() {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.copyToClipboard == true)
        #expect(store.playShutterSound == true)
        #expect(store.saveToDisk == false)
        #expect(store.showSaveNotification == true)
        #expect(store.quickAccessAutoCloseDelay == 30)
        #expect(store.saveFormat == .png)
        #expect(store.hotkeyAreaCapture == nil)
    }

    @Test("录屏默认不开麦克风，开关可持久化")
    func recordMicrophoneDefaultsAndPersists() {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.recordMicrophone == false)
        #expect(store.recordSystemAudio == false)

        store.recordMicrophone = true
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.recordMicrophone == true)
    }

    @Test("默认不设置任何热键")
    func defaultHotkeysAreEmpty() {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        for action in HotkeyAction.allCases {
            #expect(store.hotkey(for: action) == nil)
        }
    }

    @Test("多个热键各自独立持久化，清除后不再存在")
    func persistsMultipleHotkeys() {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        let windowKey = Hotkey(keyCode: 7, carbonModifiers: UInt32(optionKey))
        store.setHotkey(windowKey, for: .windowCapture)
        store.setHotkey(Hotkey(keyCode: 9, carbonModifiers: UInt32(controlKey)), for: .timedCapture)

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.hotkey(for: .windowCapture) == windowKey)
        #expect(reloaded.hotkey(for: .timedCapture)?.keyCode == 9)
        #expect(reloaded.hotkey(for: .areaCapture) == nil)

        // 清除只影响该动作。
        reloaded.setHotkey(nil, for: .windowCapture)
        let again = SettingsStore(defaults: defaults)
        #expect(again.hotkey(for: .windowCapture) == nil)
        #expect(again.hotkey(for: .timedCapture)?.keyCode == 9)
    }

    @Test("旧版本的单热键记录会迁移到区域截图")
    func migratesLegacyHotkey() throws {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = Hotkey(keyCode: 12, carbonModifiers: UInt32(controlKey))
        defaults.set(try JSONEncoder().encode(legacy), forKey: "hotkey.areaCapture")

        let store = SettingsStore(defaults: defaults)
        #expect(store.hotkey(for: .areaCapture) == legacy)
    }

    @Test("标注默认样式默认值符合预期，且能持久化")
    func annotationDefaults() {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.annotationDefaults == .standard)

        var updated = AnnotationDefaults.standard
        updated.tool = .blur
        updated.color = .blue
        updated.lineWidth = 11
        updated.rectCornerStyle = .rounded
        store.annotationDefaults = updated

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.annotationDefaults == updated)
    }

    @Test("存档里的越界样式会被夹回合法范围")
    func sanitizesStoredAnnotationDefaults() throws {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        let broken = AnnotationDefaults(
            tool: .blur,
            color: RGBAColor(red: 2, green: -1, blue: 0.5, alpha: 1),
            lineWidth: 999,
            fontSize: 0,
            mosaicBlock: -5,
            blurRadius: 9999,
            eraserSize: 0
        )
        defaults.set(try JSONEncoder().encode(broken), forKey: "annotation.defaults")

        let store = SettingsStore(defaults: defaults)
        #expect(store.annotationDefaults.tool == .blur)
        #expect(store.annotationDefaults.lineWidth == 24)
        #expect(store.annotationDefaults.fontSize == 10)
        #expect(store.annotationDefaults.blurRadius == 60)
        #expect(store.annotationDefaults.eraserSize == 8)
        #expect(store.annotationDefaults.color == RGBAColor(red: 1, green: 0, blue: 0.5, alpha: 1))
    }

    @Test("写入后重新读取能恢复")
    func persists() {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.copyToClipboard = false
        store.saveToDisk = true
        store.hotkeyAreaCapture = Hotkey(keyCode: 5, carbonModifiers: UInt32(cmdKey))

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.copyToClipboard == false)
        #expect(reloaded.saveToDisk == true)
        #expect(reloaded.hotkeyAreaCapture?.keyCode == 5)
    }

    @Test("最近截图按新到旧排序，且去重、限长")
    func recentCaptures() throws {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        // `recentCaptureURLs` 会过滤掉不存在的文件，所以要落真实文件。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SettingsStore(defaults: defaults)
        let first = directory.appendingPathComponent("a.png")
        let second = directory.appendingPathComponent("b.png")
        try Data().write(to: first)
        try Data().write(to: second)

        store.recordCapture(first)
        store.recordCapture(second)
        #expect(store.recentCaptureURLs == [second, first])

        // 重复记录应移到最前且不产生副本。
        store.recordCapture(first)
        #expect(store.recentCaptureURLs == [first, second])

        // 超出上限后只保留最近的若干条。
        for index in 0..<(SettingsStore.maxRecentCaptures + 4) {
            let url = directory.appendingPathComponent("\(index).png")
            try Data().write(to: url)
            store.recordCapture(url)
        }
        #expect(store.recentCaptureURLs.count == SettingsStore.maxRecentCaptures)

        store.clearRecentCaptures()
        #expect(store.recentCaptureURLs.isEmpty)
    }
}
