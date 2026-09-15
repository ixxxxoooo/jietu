import CoreGraphics
import Foundation
import Testing
@testable import Jietu

/// 裁剪、编码、落盘的量化验证。
///
/// @author ixxxxoooo
@Suite("截图输出")
struct CaptureOutputTests {
    private func makeSnapshot() -> DisplaySnapshot {
        // 顶两行红、底两行蓝；screenFrame 与像素等宽 → effectiveScale = 1。
        let image = TestImage.horizontalBands(
            width: 4,
            height: 4,
            rows: [(255, 0, 0), (255, 0, 0), (0, 0, 255), (0, 0, 255)]
        )
        return DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 4, height: 4),
            nominalScaleFactor: 1,
            image: image
        )
    }

    @Test("裁剪上半区得到顶行的红像素（Y 轴正确翻转）")
    func cropTopHalfIsRed() throws {
        let snapshot = makeSnapshot()
        let cropped = try #require(
            CaptureOutput.crop(snapshot, toLocalRect: CGRect(x: 0, y: 2, width: 4, height: 2))
        )
        let sample = try #require(PixelSampler.sample(cropped, atPixel: CGPoint(x: 1, y: 0)))
        #expect(sample.red == 255)
        #expect(sample.blue == 0)
    }

    @Test("裁剪下半区得到底行的蓝像素")
    func cropBottomHalfIsBlue() throws {
        let snapshot = makeSnapshot()
        let cropped = try #require(
            CaptureOutput.crop(snapshot, toLocalRect: CGRect(x: 0, y: 0, width: 4, height: 2))
        )
        let sample = try #require(PixelSampler.sample(cropped, atPixel: CGPoint(x: 1, y: 0)))
        #expect(sample.blue == 255)
        #expect(sample.red == 0)
    }

    @Test("空选区裁剪返回 nil")
    func cropEmptyReturnsNil() {
        let snapshot = makeSnapshot()
        let cropped = CaptureOutput.crop(
            snapshot,
            toLocalRect: CGRect(x: 0, y: 0, width: 0, height: 0)
        )
        #expect(cropped == nil)
    }

    @Test("PNG 编码成功")
    func pngEncode() {
        #expect(CaptureOutput.pngData(makeSnapshot().image) != nil)
    }

    @Test("同名保存自动追加序号")
    func saveAppendsCounter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = makeSnapshot().image
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try CaptureOutput.save(image, toDirectory: directory, date: date)
        let second = try CaptureOutput.save(image, toDirectory: directory, date: date)

        #expect(first.lastPathComponent != second.lastPathComponent)
        #expect(second.lastPathComponent.contains("-1"))
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("JPEG 保存使用 .jpg 扩展名")
    func saveJPEGExtension() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try CaptureOutput.save(
            makeSnapshot().image,
            toDirectory: directory,
            format: .jpeg
        )
        #expect(url.pathExtension == "jpg")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
