import SwiftUI

/// 浮动表面：磨砂 + 墨色 scrim + 圆角，用于标注工具栏 / QAO 卡片 / 控制条 / 浮窗。
///
/// 承重规则 1：表面永远是「磨砂 + scrim」，不是实心灰；
/// 规则 5：玻璃只给浮在它上面的控件，主表面永远不是 glass。
///
/// @author ixxxxoooo
struct FloatingSurface<Content: View>: View {
    /// 压底墨色，默认 `panelScrim`。
    var scrim: Color = Theme.Colors.panelScrim
    /// 磨砂材质，默认 HUD 材质。
    var material: NSVisualEffectView.Material = .hudWindow
    /// 圆角，默认浮动表面档（16）。
    var cornerRadius: CGFloat = Theme.Radius.menuPanel
    /// 是否描一条细边，让它从背景内容里「浮」出来。
    var showsBorder = true
    /// 描边颜色，默认 `cardStroke`。
    var borderColor: Color = Theme.Colors.cardStroke

    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    VisualEffectView(material: material)
                    scrim
                }
            }
            .clipShape(shape)
            .overlay {
                if showsBorder {
                    shape.strokeBorder(borderColor, lineWidth: Theme.Size.hairline)
                }
            }
    }
}

extension View {
    /// 把任意视图包成浮动表面（等价于在它外面套一个 `FloatingSurface`）。
    func floatingSurface(
        cornerRadius: CGFloat = Theme.Radius.menuPanel,
        showsBorder: Bool = true
    ) -> some View {
        FloatingSurface(cornerRadius: cornerRadius, showsBorder: showsBorder) {
            self
        }
    }
}
