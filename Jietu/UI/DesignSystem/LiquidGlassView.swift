import AppKit
import SwiftUI

/// macOS 26 的**液态玻璃**（`NSGlassEffectView`）在 SwiftUI 里的入口。
///
/// 新做的浮层走这一层，别各自去拼 `NSVisualEffectView`：液态玻璃自带折射 / 高光 / 厚度感，
/// 和系统控件（菜单、控制中心）是同一套材质。要更"穿透"就用 `.clear` 那档 style。
///
/// 注意：它只负责**底**；内容由调用方叠在上面（跟我们 `FloatingSurface` 的分工一致）。
///
/// @author ixxxxoooo
struct LiquidGlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = Theme.Radius.menuPanel
    var tint: Color?
    var style: NSGlassEffectView.Style = .regular

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSGlassEffectView) {
        view.cornerRadius = cornerRadius
        view.style = style
        view.tintColor = tint.map { NSColor($0) }
    }
}

extension View {
    /// 给浮层铺一层液态玻璃底（macOS 26+）。
    func liquidGlass(
        cornerRadius: CGFloat = Theme.Radius.menuPanel,
        tint: Color? = nil,
        style: NSGlassEffectView.Style = .regular
    ) -> some View {
        background(LiquidGlassBackground(cornerRadius: cornerRadius, tint: tint, style: style))
    }
}
