import AppKit
import SwiftUI

/// 截图后的浮动预览（Quick Access Overlay 的第一步）。
///
/// P1 只有「复制 / 保存 / 关闭」与自动关闭；
/// P2 会在这里补上拖拽、标注、钉图、可配置的自动关闭时间。
struct QuickAccessView: View {
    let image: NSImage
    let pixelSize: CGSize
    let byteSize: Int
    var onCopy: () -> Void
    var onSave: () -> Void
    var onClose: () -> Void
    var onHoverChange: (Bool) -> Void

    static let cardWidth: CGFloat = 240
    static let cardHeight: CGFloat = 206

    var body: some View {
        card
            // 阴影需要窗口内的留白；窗口自身阴影是直角矩形，已关闭。
            .padding(Theme.quickAccessShadowPadding)
    }

    private var card: some View {
        VStack(spacing: 0) {
            thumbnail
            metadata
            actions
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.quickAccessCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.quickAccessCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 18, y: 8)
        .onHover(perform: onHoverChange)
    }

    /// 磨砂只负责质感，深色底由这一层保证。
    /// 只靠 `NSVisualEffectView` 的 material 会跟随系统外观，
    /// 浅色外观下会渲染成浅底，白色文字直接看不见。
    private var cardBackground: some View {
        ZStack {
            VisualEffectBackground()
            Color.black.opacity(0.58)
        }
    }

    private var thumbnail: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 212, height: 128)
            .background(Color.black.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .padding(.top, 13)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
            Text("·")
            Text(Self.byteFormatter.string(fromByteCount: Int64(byteSize)))
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Theme.hudForeground)
        .padding(.horizontal, 14)
        .padding(.top, 9)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            actionButton("复制", symbol: "doc.on.doc", action: onCopy)
            actionButton("保存", symbol: "square.and.arrow.down", action: onSave)
            Spacer(minLength: 0)
            actionButton("关闭", symbol: "xmark", action: onClose)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickAccessButtonStyle())
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter
    }()
}

private struct QuickAccessButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovering ? Theme.hudForegroundActive : Theme.hudForeground)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.18 : 0.09))
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
