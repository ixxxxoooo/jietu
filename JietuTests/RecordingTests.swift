import AVFoundation
import CoreGraphics
import Testing
@testable import Jietu

/// 录屏的编码参数与落盘命名（引擎本体由 `--selftest-record` 端到端验）。
///
/// @author ixxxxoooo
@Suite("录屏")
struct RecordingTests {

    @Test("宽高向上取到偶数：1921 不能被截成 1920")
    func evenDimensionsRoundUp() {
        #expect(VideoEncodingSettings.even(1920) == 1920)
        #expect(VideoEncodingSettings.even(1921) == 1922)
        #expect(VideoEncodingSettings.even(1) == 2)
        #expect(VideoEncodingSettings.even(0) == 2)
        let dimensions = VideoEncodingSettings.evenDimensions(width: 1400, height: 901)
        #expect(dimensions.width == 1400)
        #expect(dimensions.height == 902)
    }

    @Test("码率：按像素×帧率估，夹在 3…80 Mbps，高分辨率收一档")
    func bitrateModel() {
        // 1080p30：1920×1080×30×0.21 ≈ 13.06 Mbps（未过 1080p 阈值，不收）。
        let fullHD = VideoEncodingSettings.bitrate(width: 1920, height: 1080, fps: 30)
        #expect(fullHD > 12_000_000 && fullHD < 14_000_000)

        // 一块很小区域：夹到下限，别写出几百 kbps 的糊片。
        #expect(VideoEncodingSettings.bitrate(width: 200, height: 120, fps: 30)
            == VideoEncodingSettings.minimumBitrate)

        // 8K：夹到上限，别写出 200 Mbps 的怪物。
        #expect(VideoEncodingSettings.bitrate(width: 7680, height: 4320, fps: 60)
            == VideoEncodingSettings.maximumBitrate)

        // 4K 比 1080p 的「每像素码率」低（收了 8%）——相同码率下高分辨率观感更好。
        let uhd = VideoEncodingSettings.bitrate(width: 3840, height: 2160, fps: 30)
        let perPixelHD = Double(fullHD) / (1920 * 1080)
        let perPixelUHD = Double(uhd) / (3840 * 2160)
        #expect(perPixelUHD < perPixelHD)
    }

    @Test("输出参数：H.264 + BT.709 + 关键帧间隔等于帧率")
    func outputSettings() {
        let settings = VideoEncodingSettings.outputSettings(width: 1401, height: 901, fps: 30)
        #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == .h264)
        #expect(settings[AVVideoWidthKey] as? Int == 1402)
        #expect(settings[AVVideoHeightKey] as? Int == 902)
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        #expect(compression?[AVVideoMaxKeyFrameIntervalKey] as? Int == 30)
        #expect(compression?[AVVideoProfileLevelKey] as? String == AVVideoProfileLevelH264HighAutoLevel)
        #expect(settings[AVVideoColorPropertiesKey] != nil)
    }

    @Test("落盘：临时文件搬进保存目录，命名走模板且同名加序号")
    func moveFileNamesLikeScreenshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-recording-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func makeTempFile() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rec-\(UUID().uuidString).mp4")
            try Data("fake".utf8).write(to: url)
            return url
        }

        let first = try CaptureOutput.moveFile(
            try makeTempFile(),
            toDirectory: directory,
            nameTemplate: "录屏 {datetime}",
            fileExtension: "mp4"
        )
        #expect(first.pathExtension == "mp4")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(first.lastPathComponent.hasPrefix("录屏 "))

        // 同一分钟里再落一个：同名自动加序号，不能覆盖第一个。
        let second = try CaptureOutput.moveFile(
            try makeTempFile(),
            toDirectory: directory,
            nameTemplate: "录屏 {datetime}",
            fileExtension: "mp4"
        )
        #expect(second != first)
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: first.path))
    }
}
