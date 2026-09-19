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
    /// 竖排（主工具栏停到左右侧、二级菜单也竖着排时）：轨道立起来，往上拖 = 调大。
    var isVertical: Bool = false

    private let thumbWidth: CGFloat = 32
    private let thumbHeight: CGFloat = 18

    var body: some View {
        if isVertical {
            verticalBody
        } else {
            horizontalBody
        }
    }

    /// 竖排：轨道从下往上由细到粗，药丸在轨道上滑动。
    private var verticalBody: some View {
        ZStack(alignment: .bottom) {
            verticalWedgePath(CGSize(width: thumbHeight, height: trackWidth))
                .fill(
                    Theme.Colors.adaptive(
                        dark: .srgbInk(1, alpha: 0.85),
                        light: .srgbInk(0, alpha: 0.92)
                    )
                )
                .frame(width: thumbHeight, height: trackWidth)

            thumb(size: CGSize(width: thumbHeight, height: thumbWidth))
                .offset(y: -verticalThumbOffset)
        }
        .frame(width: thumbHeight, height: trackWidth)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    updateValue(atTouchY: gesture.location.y)
                }
        )
    }

    /// 竖排轨道：把横排那条楔形转 90°（下细上粗）。
    private func verticalWedgePath(_ size: CGSize) -> Path {
        wedgePath(width: size.height, height: size.width)
            .applying(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.height))
    }

    /// 竖排时药丸的位移（向上为正）。
    private var verticalThumbOffset: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let progress = (value - range.lowerBound) / span
        let clampedProgress = min(max(progress, 0), 1)
        let travel = max(0, trackWidth - thumbWidth)
        return clampedProgress * travel
    }

    /// 竖排的取值：视图坐标原点在左上，越往上值越大。
    private func updateValue(atTouchY touchY: CGFloat) {
        let travel = max(1, trackWidth - thumbWidth)
        let clampedY = min(max(touchY - thumbWidth / 2, 0), travel)
        let progress = 1 - clampedY / travel
        setValue(progress: progress)
    }

    private var horizontalBody: some View {
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

            thumb(size: CGSize(width: thumbWidth, height: thumbHeight))
                .offset(x: thumbOffset)
        }
        .frame(width: trackWidth, height: thumbHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    updateValue(at: gesture.location.x)
                }
        )
    }

    /// 药丸徽标（Thumb）：横排竖排共用，只是长边朝着轨道方向、圆角按短边算。
    private func thumb(size: CGSize) -> some View {
            let radius = min(size.width, size.height) / 2
            return ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        Theme.Colors.adaptive(
                            dark: .srgbInk(0.22, alpha: 0.98),
                            light: .white
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
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
            .frame(width: size.width, height: size.height)
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
        setValue(progress: clampedX / travelWidth)
    }

    /// 按进度（0…1）落到最近的档位上。
    private func setValue(progress: CGFloat) {
        let raw = range.lowerBound + progress * (range.upperBound - range.lowerBound)
        let stepped = round(raw / step) * step
        let clamped = min(max(stepped, range.lowerBound), range.upperBound)
        if value != clamped {
            value = clamped
        }
    }
}
