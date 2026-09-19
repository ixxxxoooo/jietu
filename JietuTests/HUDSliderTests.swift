import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Jietu

@Suite("HUD控件与调色板")
struct HUDSliderTests {

    /// 按外观解析出颜色墨色的 alpha（主题色是随外观动态解析的）。
    private func inkAlpha(_ color: Color, dark: Bool) -> CGFloat {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var alpha: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            alpha = (NSColor(color).usingColorSpace(.sRGB) ?? .clear).alphaComponent
        }
        return alpha
    }

    @Test("工具栏图标比正文次要色更实，又不抢选中态")
    func toolbarIconInkIsDeeperThanSecondaryText() {
        for dark in [true, false] {
            let icon = inkAlpha(Theme.Colors.toolbarIcon, dark: dark)
            let secondary = inkAlpha(Theme.Colors.textSecondary, dark: dark)
            let primary = inkAlpha(Theme.Colors.textPrimary, dark: dark)

            #expect(icon > secondary, "工具栏图标要比 textSecondary 深")
            #expect(icon >= 0.8, "要「够深」，不能还是灰扑扑的")
            #expect(icon < primary, "选中态要更亮一档，层次不能被抹平")
        }
    }

    @Test("调色板包含 8 种基础颜色")
    func paletteCountAndColors() {
        #expect(RGBAColor.palette.count == 8)
        #expect(RGBAColor.palette[0] == .red)
        #expect(RGBAColor.palette[1] == .blue)
        #expect(RGBAColor.palette[2] == .green)
        #expect(RGBAColor.palette[3] == .yellow)
        #expect(RGBAColor.palette[4] == .orange)
        #expect(RGBAColor.palette[5] == .white)
        #expect(RGBAColor.palette[6] == .gray)
        #expect(RGBAColor.palette[7] == .black)
    }

    @Test("箭头样式包含 4 种类型")
    func arrowStylesCount() {
        #expect(ArrowStyle.allCases.count == 4)
        #expect(ArrowStyle.allCases == [.tapered, .doubleEnded, .line, .dotTail])
    }

    @Test("形状填充模式包含 3 种类型")
    func shapeFillModesCount() {
        #expect(ShapeFillMode.allCases.count == 3)
        #expect(ShapeFillMode.allCases == [.none, .opaque, .translucent])
    }

    @Test("HUDSlider 能够测量出正尺寸")
    @MainActor
    func hudSliderFittingSize() {
        var val: CGFloat = 10
        let binding = Binding(get: { val }, set: { val = $0 })
        let slider = HUDSlider(value: binding, range: 1...24, step: 1)
        let host = NSHostingView(rootView: slider)
        let size = host.fittingSize
        #expect(size.width > 0)
        #expect(size.height > 0)
    }
}
