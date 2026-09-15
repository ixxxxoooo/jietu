import AppKit
import SwiftUI

/// 截图后的浮动预览（Quick Access Overlay）。
///
/// 只展示图片预览本身（尺寸 / 体积等信息不再显示）。功能按钮放在四角、
/// 保存居中，且**仅鼠标悬停时出现**。按钮使用 macOS 26 的 Liquid Glass 材质。
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
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .background(Color.black.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .overlay { overlayControls }
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .onTapGesture { onAnnotate() }
            .onDrag { dragProvider() }
            .shadow(color: .black.opacity(0.34), radius: 12, y: 5)
            .help("点击打开标注编辑器，拖拽到其它 App 或文件夹可导出")
            .onHover { hovering in
                isHovering = hovering
                onHoverChange(hovering)
            }
    }

    /// 四角功能按钮 + 正中保存，仅悬停时出现。
    private var overlayControls: some View {
        ZStack {
            saveButton
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    cornerButton("复制", symbol: "doc.on.doc", action: onCopy)
                    Spacer(minLength: 0)
                    cornerButton("标注", symbol: "pencil.tip.crop.circle", action: onAnnotate)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    cornerButton("钉图", symbol: "pin", action: onPin)
                    Spacer(minLength: 0)
                    cornerButton("关闭", symbol: "xmark", action: onClose)
                }
            }
        }
        .padding(6)
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var saveButton: some View {
        Button(action: onSave) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 42)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("保存到磁盘")
    }

    private func cornerButton(
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
