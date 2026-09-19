import AppKit
import Testing
@testable import Jietu

/// 取色器的色号写法：`#RRGGBB` 大写，与放大镜面板上的「色值」同一套。
///
/// 系统采样器（`NSColorSampler`）要人点一下才出结果，没法在单测里跑；
/// 能钉住的是它**后面**那半截——颜色换算成色号这一段。
///
/// @author ixxxxoooo
@Suite("取色器 — 色号格式")
struct ScreenColorPickerTests {
    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    @Test("sRGB 分量直接写成大写 #RRGGBB")
    func srgbComponentsBecomeUppercaseHex() {
        #expect(color(1, 0, 0).jietu_hexString == "#FF0000")
        #expect(color(0, 0, 0).jietu_hexString == "#000000")
        #expect(color(1, 1, 1).jietu_hexString == "#FFFFFF")
        #expect(color(0.2, 0.4, 0.6).jietu_hexString == "#336699")
    }

    @Test("四舍五入到最近的 0–255，不越界")
    func componentsRoundIntoByteRange() {
        // 0.5 → 127.5 → 128；1.0 已经在端点，别溢成 256。
        #expect(color(0.5, 0, 0).jietu_hexString == "#800000")
        #expect(color(1, 1, 1).jietu_hexString == "#FFFFFF")
        #expect(color(0.999, 0, 0).jietu_hexString == "#FF0000")
    }

    @Test("别的色彩空间先换算到 sRGB 再取分量（灰度色也一样）")
    func otherColorSpacesConvertFirst() {
        // 标定白：不是 sRGB 空间，直接读 redComponent 会抛异常。
        #expect(NSColor(calibratedWhite: 1, alpha: 1).jietu_hexString == "#FFFFFF")
        #expect(NSColor(calibratedWhite: 0, alpha: 1).jietu_hexString == "#000000")
        // 泛型 RGB（deviceRGB）也得走同一条换算。
        #expect(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1).jietu_hexString == "#FF0000")
    }

    @Test("色号格式与放大镜面板同源：逐字节比一遍")
    func matchesTheLoupeFormat() {
        let sample = PixelSampler.Sample(red: 0x33, green: 0x66, blue: 0x99, alpha: 255)
        #expect(sample.hexString == color(0.2, 0.4, 0.6).jietu_hexString)
    }
}
