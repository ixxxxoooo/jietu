import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Jietu

/// 窗口截图圆角与拟物阴影特效测试。
///
/// @author ixxxxoooo
@Suite("窗口截图特效")
struct WindowEffectsTests {
    private func createSolidImage(width: Int = 100, height: Int = 100) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test("拟物复合阴影层参数计算")
    func shadowLayersCalculation() {
        let layers = WindowEffects.shadowLayers(forSize: 32)
        #expect(layers.count == 3)
        // 接触阴影、中距漫反射与大范围环境光晕依次增大模糊度
        #expect(layers[0].blur < layers[1].blur)
        #expect(layers[1].blur < layers[2].blur)
        // 投影透明度均在合理拟物范围
        for layer in layers {
            #expect(layer.opacity > 0 && layer.opacity < 1.0)
            #expect(layer.offsetY > 0)
        }

        let zeroLayers = WindowEffects.shadowLayers(forSize: 0)
        #expect(zeroLayers.isEmpty)
    }

    @Test("阴影留白外扩对称度与下倾方向")
    func shadowOutsetsCalculation() {
        let outsets = WindowEffects.shadowOutsets(forSize: 32)
        // 左右留白严格对称
        #expect(outsets.left == outsets.right)
        #expect(outsets.left > 0)
        // 拟物光源来自上方，底向投影大于顶向留白
        #expect(outsets.bottom > outsets.top)
    }

    @Test("原生圆角裁切保真且四角透明")
    func roundedCornersCrop() {
        let image = createSolidImage(width: 100, height: 100)
        let rounded = WindowEffects.roundedCorners(image: image, radiusPoints: 10, scale: 2)

        #expect(rounded.width == 100)
        #expect(rounded.height == 100)

        // 验证左下角像素为完全透明
        let bitmapRep = NSBitmapImageRep(cgImage: rounded)
        let cornerColor = bitmapRep.colorAt(x: 0, y: 0)
        #expect(cornerColor?.alphaComponent == 0.0)

        // 验证中心像素依旧保持不透明
        let centerColor = bitmapRep.colorAt(x: 50, y: 50)
        #expect(centerColor?.alphaComponent ?? 0 > 0.9)
    }

    @Test("叠加阴影画布扩展且容纳外扩")
    func withShadowExpandsCanvas() {
        let image = createSolidImage(width: 100, height: 100)
        let shadowSize: CGFloat = 32
        let scale: CGFloat = 2
        let outsets = WindowEffects.shadowOutsets(forSize: shadowSize)
        let shadowed = WindowEffects.withShadow(image: image, shadowSize: shadowSize, scale: scale)

        let expectedWidth = 100 + Int((outsets.left + outsets.right) * scale)
        let expectedHeight = 100 + Int((outsets.top + outsets.bottom) * scale)

        #expect(shadowed.width == expectedWidth)
        #expect(shadowed.height == expectedHeight)
    }

    @Test("窗口特效按开关决定是否追加阴影")
    func applyWindowEffectsToggle() {
        let image = createSolidImage(width: 80, height: 80)
        // 开启阴影：尺寸扩展
        let withShadow = WindowEffects.applyWindowEffects(to: image, shadowEnabled: true, shadowSize: 24, scale: 2)
        #expect(withShadow.width > 80)
        #expect(withShadow.height > 80)

        // 关闭阴影：保持纯圆角，尺寸与原图一致
        let withoutShadow = WindowEffects.applyWindowEffects(to: image, shadowEnabled: false, shadowSize: 24, scale: 2)
        #expect(withoutShadow.width == 80)
        #expect(withoutShadow.height == 80)
    }

    @Test("SettingsStore 窗口阴影默认值与持久化")
    func settingsStoreWindowShadowDefaults() {
        let suite = "jietu.tests.windowshadow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.windowShadowEnabled == false)
        #expect(store.windowShadowSize == 32.0)

        store.windowShadowEnabled = true
        store.windowShadowSize = 48.0

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.windowShadowEnabled == true)
        #expect(reloaded.windowShadowSize == 48.0)
    }
}
