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

    @Test("位移大小不一的多帧拼接后，每一行都与源图一致")
    func stitchesWithVaryingOffsets() throws {
        // 源图加长到 200 行，视口 40 行，位移每次不同（模拟匀速滚动时的采样抖动）。
        let source = TestImage.make(width: 6, height: 200) { _, y in
            (UInt8((y * 37) % 251), UInt8((y * 91) % 251), UInt8((y * 17) % 251))
        }
        let offsets = [0, 7, 11, 13, 20, 24]
        let frames = try offsets.map { try frame(source, from: $0, height: 40) }

        let stitched = try #require(ScrollStitcher.stitch(frames))
        // 总高度 = 首帧高度 + 各帧相对上一帧的新增行数。
        let steps = zip(offsets, offsets.dropFirst()).map { $1 - $0 }
        #expect(stitched.height == 40 + steps.reduce(0, +))
        // 逐行核对（不是抽查）：第 y 行必须等于源图第 y 行。
        for y in 0..<stitched.height {
            #expect(try row(of: stitched, at: y) == row(of: source, at: y))
        }
    }

    @Test("往回滚一帧后继续下滚：跳过的帧不参与位移，内容不错位")
    func backwardFrameDoesNotCorrupt() throws {
        let source = TestImage.make(width: 6, height: 200) { _, y in
            (UInt8((y * 37) % 251), UInt8((y * 91) % 251), UInt8((y * 17) % 251))
        }
        // 0 → 12（下滚）→ 5（往回滚一帧，接不上）→ 20（继续下滚）
        let frames = try [0, 12, 5, 20].map { try frame(source, from: $0, height: 40) }
        let stitched = try #require(ScrollStitcher.stitch(frames))

        // 往回滚的那一帧被跳过；最后一帧相对**已拼进去的**第 12 行帧位移 8。
        #expect(stitched.height == 40 + 12 + 8)
        for y in 0..<stitched.height {
            #expect(try row(of: stitched, at: y) == row(of: source, at: y))
        }
    }

    @Test("没滚动的帧不会让长图长高")
    func repeatedFrameDoesNotGrow() throws {
        let source = makeSource()
        let frameA = try frame(source, from: 0, height: 20)
        let stitched = try #require(ScrollStitcher.stitch([frameA, frameA, frameA]))
        #expect(stitched.height == 20)
    }

    @Test("滚太快、两帧没有重叠时跳过该帧而不是硬接")
    func skipsNonOverlappingFrame() throws {
        let source = try #require(TestImage.make(width: 6, height: 400) { _, y in
            (UInt8((y * 37) % 251), UInt8((y * 91) % 251), UInt8((y * 17) % 251))
        })
        let first = try frame(source, from: 0, height: 40)
        // 一次跳了 300 行：与首帧完全没有重叠。
        let far = try frame(source, from: 300, height: 40)
        #expect(ScrollStitcher.offset(previous: first, next: far) == nil)
        // 拼接时这一帧被跳过：长图仍是首帧长度，也不会画错内容。
        let stitched = try #require(ScrollStitcher.stitch([first, far]))
        #expect(stitched.height == 40)
        for y in 0..<40 {
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

    @Test("带有固定吸顶栏（Sticky Header）的页面能够正确配准与拼接")
    func stitchesWithStickyHeader() throws {
        let width = 160
        let viewportHeight = 100
        let headerHeight = 25

        // 构造一个包含 25px 吸顶导航栏与滚动正文的图像生成器
        func makeFrame(scrollOffset: Int) -> CGImage {
            let cs = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(
                data: nil,
                width: width,
                height: viewportHeight,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            // 吸顶栏：行 0..<headerHeight 恒定为红色（CGContext 顶部为 viewportHeight - headerHeight）
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: viewportHeight - headerHeight, width: width, height: headerHeight))

            // 滚动内容：行 headerHeight..<viewportHeight 随 scrollOffset 移动
            for y in headerHeight..<viewportHeight {
                let contentY = (y - headerHeight) + scrollOffset
                let g = CGFloat((contentY * 31) % 255) / 255.0
                let b = CGFloat((contentY * 73) % 255) / 255.0
                ctx.setFillColor(CGColor(red: 0, green: g, blue: b, alpha: 1))
                ctx.fill(CGRect(x: 0, y: viewportHeight - 1 - y, width: width, height: 1))
            }
            return ctx.makeImage()!
        }

        let f0 = makeFrame(scrollOffset: 0)
        let f1 = makeFrame(scrollOffset: 15)
        let f2 = makeFrame(scrollOffset: 30)

        let session = ScrollStitcher.Session(firstFrame: f0)
        let r1 = session.append(frame: f1)
        let r2 = session.append(frame: f2)

        #expect(r1 != .noNewContent)
        #expect(r2 != .noNewContent)

        let result = try #require(session.finish())
        #expect(result.width == width)
        #expect(result.height > viewportHeight)
    }

    @Test("BitmapData 判重：完全相同的画面返回 true，不同的画面返回 false")
    func bitmapNearlyIdenticalCheck() throws {
        let source = makeSource()
        let b1 = try #require(ScrollStitcher.BitmapData(image: source))
        let b2 = try #require(ScrollStitcher.BitmapData(image: source))
        #expect(b1.isNearlyIdentical(to: b2))

        let diffSource = TestImage.make(width: 8, height: 80) { _, _ in (255, 255, 255) }
        let b3 = try #require(ScrollStitcher.BitmapData(image: diffSource))
        #expect(!b1.isNearlyIdentical(to: b3))
    }
}
