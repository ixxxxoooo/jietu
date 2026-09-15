import AppKit
import SwiftUI

/// 截图后的浮动预览（Quick Access Overlay）。
///
/// 默认只显示图片预览本身；鼠标移入时**压暗图片**并浮出操作按钮：
/// 四角为圆形图标（关闭 / 钉图 / 标注 / 文字识别），中间两条胶囊按钮（复制 / 保存）。
/// 点击图片打开标注编辑器，拖拽图片可导出。
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

    static let cardWidth: CGFloat = 236
    static let cardHeight: CGFloat = 152
    private static let cornerRadius: CGFloat = 16

    /// 含阴影留白的面板尺寸。
    static var panelSize: CGSize {
        CGSize(
            width: cardWidth + Theme.quickAccessShadowPadding * 2,
            height: cardHeight + Theme.quickAccessShadowPadding * 2
        )
    }

    var body: some View {
        imageCard.padding(Theme.quickAccessShadowPadding)
    }

    private var imageCard: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.cardWidth, height: Self.cardHeight)
                .blur(radius: isHovering ? 16 : 0)
                .background(Color.black.opacity(0.28))
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
                    isHovering ? Theme.brand.opacity(0.9) : Color.white.opacity(0.10),
                    lineWidth: isHovering ? 2 : 0.5
                )
        )
        .shadow(color: .black.opacity(0.34), radius: 12, y: 5)
        .help("点击打开标注编辑器，拖拽到其它 App 或文件夹可导出")
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            onHoverChange(hovering)
        }
    }

    /// 四角圆形图标 + 中间保存按钮，仅悬停时出现。
    private var controls: some View {
        ZStack {
            pillButton("保存", symbol: "square.and.arrow.down", action: onSave)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    circleButton("关闭", symbol: "xmark", action: onClose)
                    Spacer(minLength: 0)
                    circleButton("钉图", symbol: "pin", action: onPin)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    circleButton("标注", symbol: "pencil.tip.crop.circle", action: onAnnotate)
                    Spacer(minLength: 0)
                    circleButton("复制", symbol: "doc.on.doc", action: onCopy)
                }
            }
        }
        .padding(8)
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
    }

    private func pillButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(title)
    }

    private func circleButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(title)
    }
}
