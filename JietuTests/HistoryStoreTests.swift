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
}
