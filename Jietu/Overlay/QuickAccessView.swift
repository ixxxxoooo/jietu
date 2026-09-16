import AppKit
import SwiftUI

/// 截图后的浮动预览（Quick Access Overlay）。
///
/// 默认只显示图片预览本身；鼠标移入时**压暗图片**并浮出玻璃操作按钮：
/// 四角为圆形图标（关闭 / 钉图 / 标注 / 文字识别），中间一条胶囊按钮（保存）。
/// 点击图片打开标注编辑器，拖拽图片可导出。
///
/// 表面走设计系统：磨砂 + 墨色 scrim + `Radius.menuPanel`，玻璃只给浮动按钮。
///
/// @author ixxxxoooo
struct QuickAccessView: View {
    let image: NSImage
    var onCopy: () -> Void
    var onSave: () -> Void
    var onAnnotate: () -> Void
    var onPin: () -> Void
    var onClose: () -> Void
    var onHoverChange: (Bool) -> Void
    /// 拖拽导出用：向外提供 PNG 文件。
    var dragProvider: () -> NSItemProvider

    @State private var isHovering = false

    static var cardWidth: CGFloat { Theme.Size.quickAccessCard.width }
    static var cardHeight: CGFloat { Theme.Size.quickAccessCard.height }
    private static let cornerRadius = Theme.Radius.menuPanel

    /// 含阴影留白的面板尺寸。
    static var panelSize: CGSize {
        CGSize(
            width: cardWidth + Theme.Size.quickAccessShadowPadding * 2,
            height: cardHeight + Theme.Size.quickAccessShadowPadding * 2
        )
    }

    var body: some View {
        imageCard.padding(Theme.Size.quickAccessShadowPadding)
    }

    private var imageCard: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.cardWidth, height: Self.cardHeight)
                .blur(radius: isHovering ? 16 : 0)
                // 磨砂 + 墨色 scrim 压在图片后面：不透明截图看起来原样，
                // 透明区域与悬停模糊时才露出这层底。
                .background {
                    ZStack {
                        VisualEffectView(material: .hudWindow)
                        Theme.Colors.panelScrim
                        Color.black.opacity(isHovering ? 0.30 : 0)
                    }
                }
                // 手势只挂在图片上：按钮在更上层，点按钮不会触发这里。
                .contentShape(Rectangle())
                .onTapGesture { onAnnotate() }
                .onDrag { dragProvider() }

            controls
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(
                    isHovering ? Theme.Colors.brand.opacity(0.9) : Theme.Colors.cardStroke,
                    lineWidth: isHovering ? 2 : Theme.Size.hairline
                )
        )
        .shadow(color: .black.opacity(0.34), radius: 12, y: 5)
        .help("点击打开标注编辑器，拖拽到其它 App 或文件夹可导出")
        .animation(.easeOut(duration: Theme.Duration.hover), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            onHoverChange(hovering)
        }
    }

    /// 四角圆形图标 + 中间保存按钮，仅悬停时出现。
    private var controls: some View {
        ZStack {
            GlassButton(title: "保存", systemImage: "square.and.arrow.down", action: onSave)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    GlassCircleButton(title: "关闭", systemImage: "xmark", action: onClose)
                    Spacer(minLength: 0)
                    GlassCircleButton(title: "钉图", systemImage: "pin", action: onPin)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    GlassCircleButton(
                        title: "标注", systemImage: "pencil.tip.crop.circle", action: onAnnotate)
                    Spacer(minLength: 0)
                    GlassCircleButton(title: "复制", systemImage: "doc.on.doc", action: onCopy)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
    }
}
