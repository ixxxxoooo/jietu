import AppKit
import Testing
@testable import Jietu

/// 历史条目的动作可用性、位图回退与缩略图缓存。
///
/// @author ixxxxoooo
@Suite("历史条目类型")
@MainActor
struct HistoryTypesTests {
    private func item(
        url: URL? = nil, cgImage: CGImage? = nil, image: NSImage? = nil,
        videoURL: URL? = nil, duration: TimeInterval? = nil
    ) -> HistoryItem {
        HistoryItem(
            id: UUID().uuidString, date: Date(), image: image, url: url, cgImage: cgImage,
            videoURL: videoURL, videoDuration: duration
        )
    }

    private func writePNG(width: Int, height: Int) throws -> URL {
        let image = TestImage.make(width: width, height: height) { _, _ in (200, 30, 30) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-history-types-\(UUID().uuidString).png")
        try #require(CaptureOutput.pngData(image)).write(to: url)
        return url
    }

    @Test("截图条目：复制 / 钉图 / 在访达中显示 / 编辑，顺序固定")
    func screenshotActionsInOrder() throws {
        let url = try writePNG(width: 4, height: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let actions = item(url: url).quickActions(canCopy: true, canPin: true, canReveal: true)
        #expect(actions == [.copy, .pin, .reveal, .edit])
    }

    @Test("没接对应回调的动作不露按钮；没有落盘文件就没有「在访达中显示」")
    func actionsFollowCapabilities() {
        let noFile = item()
        #expect(noFile.quickActions(canCopy: false, canPin: true, canReveal: true) == [.pin, .edit])
        #expect(noFile.quickActions(canCopy: false, canPin: false, canReveal: false) == [.edit])
    }

    @Test("录屏条目没有图像动作：只剩访达与编辑")
    func videoItemsHaveNoImageActions() {
        let url = URL(fileURLWithPath: "/tmp/demo.mp4")
        let video = item(url: url, videoURL: url, duration: 3)
        #expect(video.isVideo)
        #expect(!video.supportsImageActions)
        #expect(video.quickActions(canCopy: true, canPin: true, canReveal: true) == [.reveal, .edit])
    }

    @Test("resolvedCGImage 的优先级：会话内位图 → 磁盘原图 → 列表里的图")
    func resolvedImagePriority() throws {
        let memory = TestImage.make(width: 3, height: 2) { _, _ in (0, 0, 0) }
        let url = try writePNG(width: 10, height: 6)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(item(url: url, cgImage: memory).resolvedCGImage?.width == 3, "会话内位图优先")
        #expect(item(url: url).resolvedCGImage?.width == 10, "没有会话位图就读磁盘原图")

        let thumbnail = NSImage(size: NSSize(width: 5, height: 5), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        #expect(item(image: thumbnail).resolvedCGImage != nil, "最后回退到列表里的图")
        #expect(item().resolvedCGImage == nil)
    }

    @Test("分辨率与文件大小描述")
    func descriptions() throws {
        let memory = TestImage.make(width: 30, height: 20) { _, _ in (1, 2, 3) }
        #expect(item(cgImage: memory).resolutionDescription == "30 × 20")
        #expect(item().resolutionDescription == nil)
        #expect(item().fileSizeDescription == nil)

        let url = try writePNG(width: 8, height: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(item(url: url).fileSizeDescription?.isEmpty == false)
    }

    @Test("缩略图缓存：读得到、清得掉、不存在的文件给 nil")
    func thumbnailCache() throws {
        let url = try writePNG(width: 6, height: 6)
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = HistoryThumbnailCache()
        #expect(cache.image(for: url) != nil)
        // 文件删了，缓存里那份还在（这正是它的用途）；清掉之后就读不到了。
        try FileManager.default.removeItem(at: url)
        #expect(cache.image(for: url) != nil)
        cache.clear()
        #expect(cache.image(for: url) == nil)
        #expect(cache.image(for: URL(fileURLWithPath: "/nonexistent/jietu.png")) == nil)
    }
}
