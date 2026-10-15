import AppKit
import SwiftUI
import Testing
@testable import Jietu

/// 保存面板下方的 GIF 参数面板：能承载在 AppKit 里，并与设置双向绑定。
///
/// @author ixxxxoooo
@Suite("GIF 导出参数面板")
@MainActor
struct GifExportAccessoryViewTests {
    @Test("能作为 NSSavePanel 的附件视图承载，且有可用尺寸")
    func hostsAsAccessoryView() {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        let host = NSHostingView(rootView: GifExportAccessoryView(settings: SettingsStore(defaults: defaults)))
        let size = host.fittingSize
        #expect(size.width > 100 && size.height > 40)
    }

    @Test("面板里的帧率选项必须包含设置的默认值，否则默认态下选择器显示为空")
    func defaultFrameRateIsOffered() {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        #expect([10, 15, 24, 30].contains(store.gifFrameRate))
    }

    @Test("改动写回设置并持久化（换个实例读得回来）")
    func changesPersist() {
        let (defaults, suite) = TestUserDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.gifResolution = .width640
        store.gifFrameRate = 24
        store.gifQuality = .low

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.gifResolution == .width640)
        #expect(reloaded.gifFrameRate == 24)
        #expect(reloaded.gifQuality == .low)
    }
}
