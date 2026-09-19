import AppKit
import Testing
@testable import Jietu

/// 取色器的镜面窗口与色号：报的必须是**光标指着的那一个像素**。
///
/// 真机取像素那一步（ScreenCaptureKit）要屏幕录制授权、还得真有屏，单测里跑不了；
/// 能钉住的是它前后的两截：窗口怎么摆（摆偏一格整面镜子就错位）、
/// 以及拿回来的字节怎么写成 `#RRGGBB`。
///
/// @author ixxxxoooo
@Suite("取色器 — 镜面窗口与色号")
struct ScreenPixelProbeTests {

    @Test("镜面格数取奇数：光标那一格正好在正中")
    func cellsAreOddSoTheCursorLandsInTheMiddle() {
        #expect(ScreenPixelProbe.cells == 13)
        #expect(ScreenPixelProbe.cells % 2 == 1)
    }

    @Test("镜面窗口：以光标像素为中心，两边各让出半格")
    func windowOriginCentersOnTheCursorPixel() {
        let origin = ScreenPixelProbe.windowOrigin(cursorPointInPixels: CGPoint(x: 2400, y: 1200))
        #expect(origin == CGPoint(x: 2400 - 6, y: 1200 - 6))
    }

    @Test("光标落在小数像素上：按它所在的整数像素取窗口，不四舍五入")
    func windowOriginUsesTheContainingPixel() {
        // 光标在 (100.4, 200.9) 像素处 → 指的是像素 (100, 200)——不是四舍五入后的 (100, 201)。
        let origin = ScreenPixelProbe.windowOrigin(cursorPointInPixels: CGPoint(x: 100.4, y: 200.9))
        #expect(origin == CGPoint(x: 94, y: 194))
    }

    @Test("中心采样取的是正中那一格，色号是大写 #RRGGBB")
    func centerSampleReadsTheMiddlePixel() throws {
        let cells = ScreenPixelProbe.cells
        let image = TestImage.make(width: cells, height: cells) { x, y in
            (x == cells / 2 && y == cells / 2) ? (0xE0, 0x30, 0x30) : (0x00, 0x00, 0x00)
        }
        let sample = try #require(ScreenPixelProbe.centerSample(of: image))
        #expect(sample.hexString == "#E03030")
    }

    @Test("回执色块与色号是同一个像素的颜色")
    func pickedColorSwatchMatchesItsHex() throws {
        let picked = ScreenPixelProbe.PickedColor(
            hex: "#E03030",
            sample: PixelSampler.Sample(red: 0xE0, green: 0x30, blue: 0x30, alpha: 0xFF)
        )
        let srgb = try #require(picked.nsColor.usingColorSpace(.sRGB))
        #expect(abs(srgb.redComponent - 0xE0 / 255) < 0.004)
        #expect(abs(srgb.greenComponent - 0x30 / 255) < 0.004)
        #expect(abs(srgb.blueComponent - 0x30 / 255) < 0.004)
    }

    @Test("镜面里的每一格都能读出色号（13×13 网格不会读出界）")
    func everyCellInTheMirrorIsReadable() throws {
        let cells = ScreenPixelProbe.cells
        let image = TestImage.make(width: cells, height: cells) { x, y in
            (UInt8(x * 16 % 256), UInt8(y * 16 % 256), 0x40)
        }
        for y in 0..<cells {
            for x in 0..<cells {
                let sample = try #require(
                    PixelSampler.sample(image, atPixel: CGPoint(x: x, y: y)),
                    "第 (\(x), \(y)) 格读不到"
                )
                #expect(sample.hexString.count == 7)
                #expect(sample.hexString.hasPrefix("#"))
            }
        }
    }
}
