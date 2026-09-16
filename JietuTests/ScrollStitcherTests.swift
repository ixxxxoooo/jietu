import CoreGraphics
import Testing
@testable import Jietu

/// 滚动长图的位移计算与拼接。
///
/// @author ixxxxoooo
@Suite("滚动长图拼接")
struct ScrollStitcherTests {
    private static let rowCount = 80

    /// 每一行一个可区分的颜色，便于用行内容反推位移。
    private func makeSource() -> CGImage {
        TestImage.make(width: 8, height: Self.rowCount) { _, y in
            (
                UInt8((y * 37) % 251),
                UInt8((y * 91) % 251),
                UInt8((y * 17) % 251)
            )
        }
    }

    private func frame(_ source: CGImage, from top: Int, height: Int) throws -> CGImage {
        try #require(
            CropOperation.crop(
                source,
                to: CGRect(x: 0, y: top, width: source.width, height: height)
            )?.image
        )
    }

    private func row(of image: CGImage, at y: Int) throws -> (UInt8, UInt8, UInt8) {
        let sample = try #require(PixelSampler.sample(image, atPixel: CGPoint(x: 2, y: y)))
        return (sample.red, sample.green, sample.blue)
    }

    @Test("相邻两帧的位移按行签名算出来")
    func detectsOffset() throws {
        let source = makeSource()
        let first = try frame(source, from: 0, height: 20)
        let second = try frame(source, from: 10, height: 20)

        #expect(ScrollStitcher.offset(previous: first, next: second) == 10)
        // 同一帧自己比，位移为 0。
        #expect(ScrollStitcher.offset(previous: first, next: first) == 0)
    }

    @Test("内容完全对不上时判为接不上")
    func rejectsUnrelatedFrames() throws {
        let source = makeSource()
        let top = try frame(source, from: 0, height: 20)
        // 与首帧毫无重叠的另外一段内容。
        let far = try frame(source, from: 60, height: 20)
        #expect(ScrollStitcher.offset(previous: top, next: far) == nil)

        // 雪花噪声同样不该被判成「位移 0」以外的结果。
        let noise = TestImage.make(width: 8, height: 20) { x, y in
            (UInt8((x * 13 + y * 7) % 256), UInt8((x * 29 + y * 3) % 256), UInt8((y * 11) % 256))
        }
        let offset = ScrollStitcher.offset(previous: top, next: noise)
        #expect(offset == nil || offset == 0)
    }

    @Test("多帧拼成一张长图，内容与源图一致")
    func stitchesFrames() throws {
        let source = makeSource()
        let frames = [
            try frame(source, from: 0, height: 20),
            try frame(source, from: 10, height: 20),
            try frame(source, from: 20, height: 20),
        ]
        let stitched = try #require(ScrollStitcher.stitch(frames))
        #expect(stitched.width == source.width)
        #expect(stitched.height == 40)

        // 逐行核对：拼出来的第 y 行应当就是源图第 y 行。
        for y in [0, 9, 19, 25, 39] {
            #expect(try row(of: stitched, at: y) == row(of: source, at: y))
        }
    }

    @Test("append 只接新增的行")
    func appendsOnlyNewRows() throws {
        let source = makeSource()
        let first = try frame(source, from: 0, height: 20)
        let second = try frame(source, from: 6, height: 20)

        let merged = try #require(ScrollStitcher.append(base: first, next: second, shift: 6))
        #expect(merged.height == 26)
        #expect(try row(of: merged, at: 19) == row(of: first, at: 19))
        // 末尾 6 行来自第二帧的底部。
        #expect(try row(of: merged, at: 25) == row(of: second, at: 19))

        // shift 为 0 时不该凭空长高。
        #expect(ScrollStitcher.append(base: first, next: second, shift: 0) == nil)
    }
}
