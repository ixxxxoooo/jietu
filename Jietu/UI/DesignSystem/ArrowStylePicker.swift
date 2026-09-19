import AppKit
import SwiftUI

/// 箭头样式图标渲染（单向、双向、实心三角、圆点起笔）。
///
/// @author ixxxxoooo
struct ArrowStyleIcon: View {
    let style: ArrowStyle
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let midY = h / 2

            switch style {
            case .tapered:
                // 渐宽实心箭头（capcap 款）：尾端细圆角，箭身由细至粗，头部翼缘展开后收于箭头顶点
                var path = Path()
                path.move(to: CGPoint(x: w - 2, y: midY))
                path.addLine(to: CGPoint(x: w - 8, y: midY - 4.5))
                path.addLine(to: CGPoint(x: w - 7.5, y: midY - 1.8))
                path.addLine(to: CGPoint(x: 3, y: midY - 1.0))
                path.addArc(
                    center: CGPoint(x: 3, y: midY),
                    radius: 1.0,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(90),
                    clockwise: false
                )
                path.addLine(to: CGPoint(x: w - 7.5, y: midY + 1.8))
                path.addLine(to: CGPoint(x: w - 8, y: midY + 4.5))
                path.closeSubpath()
                context.fill(path, with: .color(color))

            case .doubleEnded:
                // 双向箭头：中间直杆 + 两端实心三角箭头
                var line = Path()
                line.move(to: CGPoint(x: 5, y: midY))
                line.addLine(to: CGPoint(x: w - 5, y: midY))
                context.stroke(line, with: .color(color), lineWidth: 1.8)

                var left = Path()
                left.move(to: CGPoint(x: 2, y: midY))
                left.addLine(to: CGPoint(x: 6.5, y: midY - 3.5))
                left.addLine(to: CGPoint(x: 6.5, y: midY + 3.5))
                left.closeSubpath()
                context.fill(left, with: .color(color))

                var right = Path()
                right.move(to: CGPoint(x: w - 2, y: midY))
                right.addLine(to: CGPoint(x: w - 6.5, y: midY - 3.5))
                right.addLine(to: CGPoint(x: w - 6.5, y: midY + 3.5))
                right.closeSubpath()
                context.fill(right, with: .color(color))

            case .line:
                // 直箭头：单直杆 + 右端实心三角箭头
                var line = Path()
                line.move(to: CGPoint(x: 2, y: midY))
                line.addLine(to: CGPoint(x: w - 5, y: midY))
                context.stroke(line, with: .color(color), lineWidth: 1.8)

                var head = Path()
                head.move(to: CGPoint(x: w - 2, y: midY))
                head.addLine(to: CGPoint(x: w - 6.5, y: midY - 3.5))
                head.addLine(to: CGPoint(x: w - 6.5, y: midY + 3.5))
                head.closeSubpath()
                context.fill(head, with: .color(color))

            case .dotTail:
                // 圆点箭头：左端实心圆点 + 直杆 + 右端实心三角箭头
                let dotRect = CGRect(x: 2, y: midY - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: dotRect), with: .color(color))

                var line = Path()
                line.move(to: CGPoint(x: 6.5, y: midY))
                line.addLine(to: CGPoint(x: w - 5, y: midY))
                context.stroke(line, with: .color(color), lineWidth: 1.8)

                var head = Path()
                head.move(to: CGPoint(x: w - 2, y: midY))
                head.addLine(to: CGPoint(x: w - 6.5, y: midY - 3.5))
                head.addLine(to: CGPoint(x: w - 6.5, y: midY + 3.5))
                head.closeSubpath()
                context.fill(head, with: .color(color))
            }
        }
        .frame(width: 22, height: 16)
    }
}

/// 箭头样式切换控件。
///
/// @author ixxxxoooo
struct ArrowStylePicker: View {
    @Binding var selectedStyle: ArrowStyle
    /// 竖排（二级菜单竖着排时）。
    var isVertical: Bool = false

    var body: some View {
        stack {
            ForEach(ArrowStyle.allCases) { style in
                let isSelected = selectedStyle == style
                Button {
                    selectedStyle = style
                } label: {
                    ArrowStyleIcon(
                        style: style,
                        color: isSelected ? Theme.Colors.selectionGreen : Theme.Colors.toolbarIcon
                    )
                    .frame(width: 28, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? Theme.Colors.controlSurface : Color.black.opacity(0.001))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(style.title)
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
