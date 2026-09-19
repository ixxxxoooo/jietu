import AppKit
import SwiftUI

/// 跟随光标的**像素放大镜**：尺寸与卡片外观的唯一来源。
///
/// 两个入口共用这一套 —— 截图遮罩的放大镜（`OverlayCanvasView+Loupe`）与取色器
/// （`ColorPickerCard`）：同样的 136pt 镜面、13×13 格，同一块液态玻璃卡片，同一组读数行。
/// 要改外观改这里，两边不会各自漂。
///
/// @author ixxxxoooo
enum PixelLoupe {
    /// 镜面边长（point）。
    static let side: CGFloat = 136
    /// 网格格数（奇数：光标那一格正好在正中）。
    static let cells = 13
    /// 一格边长。一格 = 图像的一个像素，所以它同时就是放大倍率。
    static let cellSide: CGFloat = side / CGFloat(cells)
    /// 卡片与光标之间的间距。
    static let gap: CGFloat = 16
    /// 卡片内边距。
    static let padding = Theme.Spacing.lg

    /// 卡片围着镜面展开时，镜面左上角在卡片里的位置。
    ///
    /// 调度方（`OverlayCanvasView+Loupe`）要靠它把卡片摆对位置，所以和上面的布局参数放一起。
    static func mirrorOrigin(in cardHeight: CGFloat) -> CGPoint {
        CGPoint(x: padding, y: cardHeight - padding - side)
    }
}

/// 镜面：光标周围那一小块画面逐像素放大（不插值）+ 网格 + 光标格。
///
/// 光标格的位置是**传进来的**：贴着屏幕边时采样窗口会被夹回图内，光标格就不再落在正中。
///
/// @author ixxxxoooo
struct PixelLoupeMirror: View {
    /// 采样窗口那块画面，一共 `cells × cells` 像素。
    var image: CGImage?
    /// 光标那一格在镜面里的位置（左上角为 0）。
    var cursorCell: CGPoint

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(.black.opacity(0.25))

            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)  // 像素级放大：插值一糊就没法抠色了
                    .resizable()
                    .frame(width: PixelLoupe.side, height: PixelLoupe.side)
            }

            grid
            cursorCellOutline
        }
        .frame(width: PixelLoupe.side, height: PixelLoupe.side)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: Theme.Size.hairline)
        )
    }

    /// 格线：细白线垫一道更淡的黑线，深浅画面上都看得见。
    ///
    /// 线宽取 0.5pt（2x 屏上正好一个像素）：镜面是用来抠像素的，线粗一分就多压住一格。
    private var grid: some View {
        Canvas { context, size in
            var path = Path()
            for index in 1..<PixelLoupe.cells {
                let offset = (CGFloat(index) * PixelLoupe.cellSide).rounded()
                path.move(to: CGPoint(x: offset, y: 0))
                path.addLine(to: CGPoint(x: offset, y: size.height))
                path.move(to: CGPoint(x: 0, y: offset))
                path.addLine(to: CGPoint(x: size.width, y: offset))
            }
            context.stroke(path, with: .color(.black.opacity(0.28)), lineWidth: 0.5)
            context.stroke(path, with: .color(.white.opacity(0.22)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    /// 光标那一格：黑垫底 + 白描边 —— 白线落在白色画面上也不丢。
    private var cursorCellOutline: some View {
        ZStack {
            Rectangle().strokeBorder(.black.opacity(0.45), lineWidth: 2)
            Rectangle().strokeBorder(.white.opacity(0.95), lineWidth: 1.5)
        }
        .frame(width: PixelLoupe.cellSide, height: PixelLoupe.cellSide)
        .position(
            x: (cursorCell.x + 0.5) * PixelLoupe.cellSide,
            y: (cursorCell.y + 0.5) * PixelLoupe.cellSide
        )
        .allowsHitTesting(false)
    }
}

/// 放大镜卡片的宿主：**从不接收鼠标事件**。
///
/// 卡片贴在光标旁边、贴边时还会被夹到光标底下 —— 它要是吃掉那一下点击或拖拽，
/// 取色 / 框选就哑了。它只是一条读数，永远不该参与命中测试。
///
/// @author ixxxxoooo
final class PixelLoupeCardHost<Card: View>: NSHostingView<Card> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 放大镜卡片：镜面在上、读数在下，整块是一层液态玻璃。
///
/// 用玻璃而不是不透明面板：镜子只是贴在光标旁边的一条读数，取色 / 框选时还得看得见下面是什么。
///
/// @author ixxxxoooo
struct PixelLoupeCard<Readout: View>: View {
    var image: CGImage?
    var cursorCell: CGPoint
    @ViewBuilder var readout: Readout

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            PixelLoupeMirror(image: image, cursorCell: cursorCell)
            readout
        }
        .padding(PixelLoupe.padding)
        .liquidGlass(cornerRadius: Theme.Radius.menuPanel)
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    }
}

/// 读数行：标签（次级墨）+ 数值（等宽数字 —— 跟着光标刷新时不会左右抖）。
///
/// @author ixxxxoooo
struct PixelLoupeReadoutRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}

/// 色值行：色块 + 等宽色号 —— 放大镜报的、取色器复制的，是同一个东西。
///
/// @author ixxxxoooo
struct PixelLoupeHexRow: View {
    var hex: String?
    var swatch: NSColor?

    private static let swatchSide: CGFloat = 16

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            RoundedRectangle(cornerRadius: Theme.Radius.glyph, style: .continuous)
                .fill(swatch.map { Color(nsColor: $0) } ?? .clear)
                .frame(width: Self.swatchSide, height: Self.swatchSide)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.glyph, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: Theme.Size.hairline)
                )

            Text(hex ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}
