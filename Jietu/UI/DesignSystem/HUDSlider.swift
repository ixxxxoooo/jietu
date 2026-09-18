import AppKit
import SwiftUI

/// capcap 风格的悬浮 HUD 滑块：细到粗楔形轨道 + 内含当前数值的药丸徽标。
///
/// @author ixxxxoooo
struct HUDSlider: View {
    @Binding var value: CGFloat
    var range: ClosedRange<CGFloat>
    var step: CGFloat = 1
    var trackWidth: CGFloat = 96
    var trackHeight: CGFloat = 14

    private let thumbWidth: CGFloat = 32
    private let thumbHeight: CGFloat = 18

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .leading) {
                // 楔形轨道底图
                wedgePath(width: trackWidth, height: trackHeight)
                    .fill(
                        Theme.Colors.adaptive(
                            dark: .srgbInk(1, alpha: 0.85),
                            light: .srgbInk(0, alpha: 0.92)
                        )
                    )
                    .frame(width: trackWidth, height: trackHeight)

                // 药丸徽标（Thumb）
                ZStack {
                    RoundedRectangle(cornerRadius: thumbHeight / 2, style: .continuous)
                        .fill(
                            Theme.Colors.adaptive(
                                dark: .srgbInk(0.22, alpha: 0.98),
                                light: .white
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: thumbHeight / 2, style: .continuous)
                                .strokeBorder(
                                    Theme.Colors.adaptive(
                                        dark: .srgbInk(1, alpha: 0.18),
                                        light: .srgbInk(0, alpha: 0.15)
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .shadow(
                            color: Color.black.opacity(0.12),
                            radius: 2,
                            x: 0,
                            y: 1
                        )

                    Text("\(Int(round(value)))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            Theme.Colors.adaptive(
                                dark: .white,
                                light: .black
                            )
                        )
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                .frame(width: thumbWidth, height: thumbHeight)
                .offset(x: thumbOffset)
            }
            .frame(width: trackWidth, height: thumbHeight, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        updateValue(at: gesture.location.x)
                    }
            )
        }
        .frame(width: trackWidth, height: thumbHeight)
    }

    /// 绘制细到粗楔形轨道
    private func wedgePath(width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        guard width > 0, height > 0 else { return path }

        let minHeight: CGFloat = 3.5
        let maxHeight: CGFloat = 13.0
        let midY = height / 2
        let startHalf = minHeight / 2
        let endHalf = min(maxHeight, height) / 2

        // 左端圆弧
        path.addArc(
            center: CGPoint(x: startHalf, y: midY),
            radius: startHalf,
            startAngle: .degrees(90),
            endAngle: .degrees(270),
            clockwise: false
        )

        // 顶边：从左上向右上倾斜
        path.addLine(to: CGPoint(x: width - endHalf, y: midY - endHalf))

        // 右端圆弧
        path.addArc(
            center: CGPoint(x: width - endHalf, y: midY),
            radius: endHalf,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )

        // 底边：从右下向左下倾斜
        path.addLine(to: CGPoint(x: startHalf, y: midY + startHalf))

        path.closeSubpath()
        return path
    }

    /// 药丸当前水平偏移量（X 轴位置）：滑动范围为 [0, trackWidth - thumbWidth]
    private var thumbOffset: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let progress = (value - range.lowerBound) / span
        let clampedProgress = min(max(progress, 0), 1)
        let travelWidth = max(0, trackWidth - thumbWidth)
        return clampedProgress * travelWidth
    }

    private func updateValue(at touchX: CGFloat) {
        let travelWidth = max(1, trackWidth - thumbWidth)
        let clampedX = min(max(touchX - thumbWidth / 2, 0), travelWidth)
        let progress = clampedX / travelWidth
        let raw = range.lowerBound + progress * (range.upperBound - range.lowerBound)
        let stepped = round(raw / step) * step
        let clamped = min(max(stepped, range.lowerBound), range.upperBound)
        value = clamped
    }
}
