import AppKit
import SwiftUI

/// 浮动表面：Liquid Glass 玻璃面板，用于标注工具栏 / 控制条 / 浮窗等所有浮在内容上的栏。
///
/// 直接用系统的 `glassEffect(.regular)`：折射、高光、边缘与明暗自适应都由系统负责，
/// 不再自己叠磨砂 + scrim + 描边。内容本身保持平（悬停 / 选中只压一层墨），
/// **不要在玻璃里再嵌玻璃**——玻璃叠玻璃会采样到自己，发灰发糊。
///
/// @author ixxxxoooo
struct FloatingSurface<Content: View>: View {
    /// 圆角，默认浮动表面档（16）。
    var cornerRadius: CGFloat = Theme.Radius.menuPanel
    /// 是否裁剪内容。默认 false，允许浮动控件的 tooltip / 气泡等浮在表面外。
    var clipsContent = false

    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let surface = content.glassEffect(.regular, in: shape)
        if clipsContent {
            surface.clipShape(shape)
        } else {
            surface
        }
    }
}

extension View {
    /// 把任意视图包成 Liquid Glass 浮动表面（等价于在它外面套一个 `FloatingSurface`）。
    func floatingSurface(
        cornerRadius: CGFloat = Theme.Radius.menuPanel,
        clipsContent: Bool = false
    ) -> some View {
        FloatingSurface(cornerRadius: cornerRadius, clipsContent: clipsContent) {
            self
        }
    }
}

extension NSGlassEffectView {
    /// AppKit 面板用的 Liquid Glass 表面（Toast、GIF 进度、录制控制条等不走 SwiftUI 的浮层）。
    ///
    /// - Parameters:
    ///   - cornerRadius: 圆角，默认浮动表面档。
    ///   - content: 放进玻璃里的内容；传 nil 时只当底（内容由调用方作为兄弟视图叠在上面）。
    static func floatingSurface(
        cornerRadius: CGFloat = Theme.Radius.menuPanel,
        content: NSView? = nil
    ) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = cornerRadius
        view.contentView = content
        return view
    }
}
