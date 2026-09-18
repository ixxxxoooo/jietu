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
            case .standard:
                var line = Path()
                line.move(to: CGPoint(x: 2, y: midY))
                line.addLine(to: CGPoint(x: w - 2, y: midY))
                context.stroke(line, with: .color(color), lineWidth: 1.6)

                var head = Path()
                head.move(to: CGPoint(x: w - 7, y: midY - 4))
                head.addLine(to: CGPoint(x: w - 2, y: midY))
                head.addLine(to: CGPoint(x: w - 7, y: midY + 4))
                context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            case .doubleEnded:
                var line = Path()
                line.move(to: CGPoint(x: 3, y: midY))
                line.addLine(to: CGPoint(x: w - 3, y: midY))
                context.stroke(line, with: .color(color), lineWidth: 1.6)

                var leftHead = Path()
                leftHead.move(to: CGPoint(x: 7, y: midY - 3.5))
                leftHead.addLine(to: CGPoint(x: 3, y: midY))
                leftHead.addLine(to: CGPoint(x: 7, y: midY + 3.5))
                context.stroke(leftHead, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                var rightHead = Path()
                rightHead.move(to: CGPoint(x: w - 7, y: midY - 3.5))
                rightHead.addLine(to: CGPoint(x: w - 3, y: midY))
                rightHead.addLine(to: CGPoint(x: w - 7, y: midY + 3.5))
                context.stroke(rightHead, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            case .tapered:
                var line = Path()
                line.move(to: CGPoint(x: 2, y: midY))
                line.addLine(to: CGPoint(x: w - 8, y: midY))
                context.stroke(line, with: .color(color), lineWidth: 1.6)

                var tri = Path()
                tri.move(to: CGPoint(x: w - 8, y: midY - 4.5))
                tri.addLine(to: CGPoint(x: w - 1, y: midY))
                tri.addLine(to: CGPoint(x: w - 8, y: midY + 4.5))
                tri.closeSubpath()
                context.fill(tri, with: .color(color))

            case .dotTail:
                let dotRadius: CGFloat = 2.5
                let dotRect = CGRect(x: 2, y: midY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                context.fill(Path(ellipseIn: dotRect), with: .color(color))

                var line = Path()
                line.move(to: CGPoint(x: 2 + dotRadius * 2, y: midY))
                line.addLine(to: CGPoint(x: w - 2, y: midY))
                context.stroke(line, with: .color(color), lineWidth: 1.6)

                var head = Path()
                head.move(to: CGPoint(x: w - 7, y: midY - 4))
                head.addLine(to: CGPoint(x: w - 2, y: midY))
                head.addLine(to: CGPoint(x: w - 7, y: midY + 4))
                context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
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

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ArrowStyle.allCases) { style in
                let isSelected = selectedStyle == style
                Button {
                    selectedStyle = style
                } label: {
                    ArrowStyleIcon(
                        style: style,
                        color: isSelected ? Theme.Colors.selectionGreen : Theme.Colors.textSecondary
                    )
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? Theme.Colors.controlSurface : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .help(style.title)
            }
        }
    }
}
