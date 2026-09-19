import AppKit
import Testing
@testable import Jietu

/// 「最近截图」的落盘历史：**重启后还该有数据**（这是用户报的那个 bug）。
///
/// @author ixxxxoooo
@Suite("最近截图历史")
@MainActor
struct HistoryStoreTests {
    private func makeStore() -> (HistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-history-test-\(UUID().uuidString)", isDirectory: true)
        return (HistoryStore(directory: directory), directory)
    }

    private func image(width: Int = 40, height: Int = 30) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.systemPink.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test("记一张截图会落盘，并且**换个实例读同一个目录**还看得到（= 重启后还有数据）")
    func recordedCaptureSurvivesReopen() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let entry = try #require(store.record(image()))
        #expect(FileManager.default.fileExists(atPath: entry.historyPath), "截图要真的落到历史目录里")

        let reopened = HistoryStore(directory: directory)
        #expect(reopened.entries.count == 1)
        #expect(reopened.entries.first?.id == entry.id)
        #expect(reopened.entries.first?.displayURL.path == entry.historyPath)
    }

    @Test("最新的在最前；回填用户保存的那份后，打开/显示优先用它")
    func newestFirstAndSavedFileWins() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.record(image(), date: Date(timeIntervalSince1970: 100))
        let newer = try #require(store.record(image(), date: Date(timeIntervalSince1970: 200)))
        #expect(store.entries.first?.id == newer.id, "新的在前")

        let saved = directory.appendingPathComponent("用户自己存的那份.png")
        store.attachSavedFile(saved, to: newer.id)
        let entry = try #require(store.entries.first)
        #expect(entry.savedPath == saved.path)
        #expect(entry.displayURL == saved, "有用户那份时，显示 / 打开都该落到它上面")

        // 回填也要持久化。
        let reopened = HistoryStore(directory: directory)
        #expect(reopened.entries.first?.savedPath == saved.path)
    }

    @Test("超过条数上限丢最旧的，文件一起删")
    func prunesOldestBeyondLimit() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var firstPath: String?
        for index in 0...HistoryStore.maxEntries {
            let entry = store.record(image(), date: Date(timeIntervalSince1970: TimeInterval(index)))
            if firstPath == nil { firstPath = entry?.historyPath }
        }
        #expect(store.entries.count == HistoryStore.maxEntries)
        let oldest = try #require(firstPath)
        #expect(!FileManager.default.fileExists(atPath: oldest), "被挤掉那条的文件也要删")
    }

    @Test("清除记录：条目与文件一起清掉，重启也回不来")
    func removeAllClearsEverything() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let entry = try #require(store.record(image()))
        store.removeAll()
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: entry.historyPath))
        #expect(HistoryStore(directory: directory).entries.isEmpty)
    }

    @Test("历史目录被谁清掉过：索引里那些找不到文件的条目下次读时丢掉")
    func dropsEntriesWhoseFileIsGone() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let entry = try #require(store.record(image()))
        try FileManager.default.removeItem(atPath: entry.historyPath)
        #expect(HistoryStore(directory: directory).entries.isEmpty)
    }

    @Test("录屏进「最近记录」：只存封面缩略图，本体留在保存目录，点开给的是视频")
    func recordsVideoWithoutCopyingIt() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 造一个「录屏文件」放在别处（模拟用户的保存目录）。
        let videoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-video-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: videoDirectory) }
        let videoURL = videoDirectory.appendingPathComponent("录屏.mp4")
        try Data("fake".utf8).write(to: videoURL)

        let entry = try #require(
            store.recordVideo(at: videoURL, cover: image(), duration: 12.5)
        )
        #expect(entry.isVideo)
        #expect(entry.videoDuration == 12.5)
        #expect(entry.openURL == videoURL, "点开要落到视频本体上")
        #expect(entry.historyURL.pathExtension == "png", "历史目录里存的是封面 PNG")
        #expect(entry.historyURL.path != videoURL.path)
        #expect(FileManager.default.fileExists(atPath: videoURL.path), "视频本体不许被搬走/复制")

        // 换个实例读同一个目录（= 重启）：条目还在，封面也读得回来。
        let reopened = HistoryStore(directory: directory)
        let restored = try #require(reopened.entries.first)
        #expect(restored.isVideo)
        #expect(restored.videoDuration == 12.5)
        #expect(restored.openURL == videoURL)
        #expect(FileManager.default.fileExists(atPath: restored.historyPath))
    }

    @Test("录屏本体被删掉后，重启读索引时这条要丢掉（点不开的条目不该留在菜单里）")
    func dropsVideoEntriesWhoseFileIsGone() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-gone-\(UUID().uuidString).mp4")
        try Data("fake".utf8).write(to: videoURL)
        store.recordVideo(at: videoURL, cover: image(), duration: 3)
        #expect(store.entries.count == 1)

        try FileManager.default.removeItem(at: videoURL)
        let reopened = HistoryStore(directory: directory)
        #expect(reopened.entries.isEmpty, "本体没了，这条就该消失")
    }
}
