import SwiftUI

/// 悬停提示气泡的出现方位。
///
/// @author ixxxxoooo
enum TooltipPlacement {
    case top
    case bottom
}

/// 符合 Jietu UI 规范的悬停提示标签（气泡）。
///
/// 承重规则对齐：
/// 1. 表面 = 磨砂 + 墨色 scrim（`VisualEffectView(.hudWindow)` + `Theme.Colors.panelScrim`）；
/// 2. 只有一条 alpha ramp，不用灰（`Theme.Colors.textPrimary` + `Theme.Colors.border`）；
/// 4. 边角是溶解不是裁切（`Capsule`）；
/// 5. 动画时长取设计令牌 `Theme.Duration.tooltip`（0.15s）。
///
/// @author ixxxxoooo
struct TooltipView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .background {
                Capsule()
                    .fill(Theme.Colors.panelScrim)
                    .background(
                        VisualEffectView(material: .hudWindow)
                            .clipShape(Capsule())
                    )
            }
            .overlay {
                Capsule()
                    .strokeBorder(Theme.Colors.border, lineWidth: Theme.Size.hairline)
            }
            .shadow(
                color: Theme.Colors.adaptive(
                    dark: .srgbInk(0, alpha: 0.35),
                    light: .srgbInk(0, alpha: 0.12)
                ),
                radius: 4,
                x: 0,
                y: 1.5
            )
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// 为视图附加符合 UI 规范的悬停气泡提示。
///
/// @author ixxxxoooo
private struct TooltipModifier: ViewModifier {
    let text: String?
    var placement: TooltipPlacement = .top
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                guard let text, !text.isEmpty else {
                    hovered = false
                    return
                }
                hovered = isHovering
            }
            .overlay(alignment: placement == .top ? .top : .bottom) {
                if let text, !text.isEmpty, hovered {
                    TooltipView(text: text)
                        .offset(y: placement == .top ? -28 : 28)
                        .transition(
                            .opacity.combined(
                                with: .scale(scale: 0.94, anchor: placement == .top ? .bottom : .top)
                            )
                        )
                }
            }
            .animation(.easeOut(duration: Theme.Duration.tooltip), value: hovered)
    }
}

extension View {
    /// 悬停提示气泡（气泡样式与按键芯片一致，替代系统原生的黄色/灰色 tooltip）。
    func tooltip(_ text: String?, placement: TooltipPlacement = .top) -> some View {
        modifier(TooltipModifier(text: text, placement: placement))
    }
}
