import SwiftUI

/// 通用样式图标选择器：多个样式值以网格排列，选中态高亮，支持横排/竖排。
///
/// 三个现有 Picker（箭头、矩形角、填充模式）共享相同的按钮布局与选中态逻辑，
/// 差异仅在图标渲染。用此泛型组件统一结构，各 Picker 只需提供图标 ViewBuilder。
///
/// @author ygw
struct StyleIconPicker<Style: Hashable & CaseIterable & Identifiable>: View
where Style.AllCases: RandomAccessCollection {
    @Binding var selected: Style
    /// 竖排（二级菜单竖着排时）。
    var isVertical: Bool = false
    /// 每个选项的标题（用于无障碍 `.help`）。
    let title: (Style) -> String
    /// 图标渲染，`isSelected` 指示当前是否选中。
    @ViewBuilder let icon: (Style, Bool) -> any View

    var body: some View {
        stack {
            ForEach(Array(Style.allCases)) { style in
                let isSelected = selected == style
                Button {
                    selected = style
                } label: {
                    AnyView(icon(style, isSelected))
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isSelected ? Theme.Colors.controlSurface : Color.black.opacity(0.001))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .focusEffectDisabled()
                .help(title(style))
            }
        }
    }

    /// 横排 / 竖排两种走向（竖排时二级菜单是窄窄一条）。
    @ViewBuilder private func stack<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if isVertical {
            VStack(spacing: 2, content: content)
        } else {
            HStack(spacing: 3, content: content)
        }
    }
}
