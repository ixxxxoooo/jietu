import Testing
@testable import Jietu

/// GIF 导出的三个纯函数：下采样步长、帧间隔、输出尺寸。
///
/// 真正解码 + 编码那条链路要真文件（自检里跑），这里钉的是「算错就会出怪文件」的部分。
///
/// @author ixxxxoooo
@Suite("GIF 导出")
struct GifExporterTests {

    @Test("下采样步长：按源帧率 / 目标帧率取整，至少 1")
    func samplingStep() {
        #expect(GifExporter.step(sourceFps: 30, targetFps: 10) == 3)
        #expect(GifExporter.step(sourceFps: 60, targetFps: 10) == 6)
        #expect(GifExporter.step(sourceFps: 29.97, targetFps: 10) == 3)
        // 源比目标还低：不抽帧（step 不能是 0）。
        #expect(GifExporter.step(sourceFps: 8, targetFps: 10) == 1)
        #expect(GifExporter.step(sourceFps: 0, targetFps: 10) == 1)
        #expect(GifExporter.step(sourceFps: 30, targetFps: 0) == 1)
    }

    @Test("帧间隔：GIF 的 delay 以 10ms 计数，10fps 正好落在精度上")
    func frameDelay() {
        #expect(GifExporter.frameDelay(for: 10) == 0.1)
        #expect(GifExporter.frameDelay(for: 25) == 0.04)
        #expect(GifExporter.frameDelay(for: 20) == 0.05)
        // 非法帧率也不能给出 0（delay 为 0 的 GIF 很多播放器直接跳过帧）。
        #expect(GifExporter.frameDelay(for: 0) == 0.1)
    }

    @Test("输出尺寸：等比缩到目标宽、取偶、不放大")
    func outputSize() {
        // 1080p → 480 宽（480×270）。
        let fullHD = GifExporter.outputSize(sourceWidth: 1920, sourceHeight: 1080, targetWidth: 480)
        #expect(fullHD.width == 480)
        #expect(fullHD.height == 270)

        // 4:3 的 640×480 → 480×360。
        let fourThree = GifExporter.outputSize(sourceWidth: 640, sourceHeight: 480, targetWidth: 480)
        #expect(fourThree.width == 480)
        #expect(fourThree.height == 360)

        // 比目标还窄：保持原宽，不做插值放大。
        let small = GifExporter.outputSize(sourceWidth: 320, sourceHeight: 240, targetWidth: 480)
        #expect(small.width == 320)
        #expect(small.height == 240)

        // 奇数高向上取到偶数（H.264 解出来的尺寸未必是偶数）。
        let odd = GifExporter.outputSize(sourceWidth: 800, sourceHeight: 301, targetWidth: 400)
        #expect(odd.width == 400)
        #expect(odd.height == 150 || odd.height == 152)

        // 退化输入不崩、也不产出 0 尺寸。
        let degenerate = GifExporter.outputSize(sourceWidth: 0, sourceHeight: 0, targetWidth: 480)
        #expect(degenerate.width >= 2 && degenerate.height >= 2)
    }

    @Test("GifResolution 尺寸计算：视网膜 1x、原始尺寸与宽度上限")
    func gifResolutionCalculation() {
        // Retina 2x 屏幕 (2880×1800) -> 视网膜 1x (50%) 还原为 1440×900
        let retina = GifResolution.retina1x.calculateSize(sourceWidth: 2880, sourceHeight: 1800)
        #expect(retina.width == 1440)
        #expect(retina.height == 900)

        // 100% 原始尺寸保持原样 (1920×1080)
        let orig = GifResolution.original.calculateSize(sourceWidth: 1920, sourceHeight: 1080)
        #expect(orig.width == 1920)
        #expect(orig.height == 1080)

        // 75% 高清 (1600×1200) -> 1200×900
        let scale75 = GifResolution.scale75.calculateSize(sourceWidth: 1600, sourceHeight: 1200)
        #expect(scale75.width == 1200)
        #expect(scale75.height == 900)

        // 限制宽度 960：当源宽度大于 960 时等比缩小
        let width960 = GifResolution.width960.calculateSize(sourceWidth: 1920, sourceHeight: 1080)
        #expect(width960.width == 960)
        #expect(width960.height == 540)

        // 限制宽度 960：当源宽度小于 960 时不放大
        let small960 = GifResolution.width960.calculateSize(sourceWidth: 600, sourceHeight: 400)
        #expect(small960.width == 600)
        #expect(small960.height == 400)
    }

    @Test("15fps 与 30fps 帧间隔计算")
    func frameDelayHighRates() {
        #expect(GifExporter.frameDelay(for: 15) == 0.07)
        #expect(GifExporter.frameDelay(for: 30) == 0.03)
    }
}
