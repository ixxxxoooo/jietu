import AppKit
import SwiftUI

/// 滚动长图的**实时预览**：贴在选区右侧（放不下就翻到左侧）的一条窄窗，
/// 顶部与选区对齐，整体等比显示已经拼好的长图。
///
/// 照 capcap 的 `ScrollPreviewWindow`：
/// - 无边框、不激活、**鼠标穿透**（绝不抢输入）；
/// - 层级高于遮罩（否则会被压暗）；
/// - 缩略图先降采样再显示，不然每 0.25 秒把两万像素高的图交给 SwiftUI 会很吃力。
///
/// @author ixxxxoooo
@MainActor
final class ScrollingPreviewPanel {
    /// 窄条尺寸（capcap 用 120×400）。
    static let size = CGSize(width: 124, height: 408)

    /// 预览**图**的像素尺寸：与面板内容区同比例、按屏幕缩放算。
    ///
    /// 拼图那边按这个尺寸开一块小画布、只增量往里画新内容——所以预览的渲染开销
    /// 跟长图总长无关（以前是把整张长图丢给 SwiftUI 缩放，越滚越卡）。
    static var previewPixelSize: CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let inset = Theme.Spacing.xs * 2
        return CGSize(
            width: max(1, (size.width - inset) * scale),
            height: max(1, (size.height - inset) * scale)
        )
    }
    private static let inset: CGFloat = Theme.Spacing.xs
    private static let gap: CGFloat = 12

    private var panel: NSPanel?
    private var hosting: NSHostingView<ScrollingPreviewView>?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 贴在选区右侧（右边放不下就翻到左侧），顶部对齐。
    func present(near selectionRect: CGRect) {
        close()

        let hosting = NSHostingView(rootView: ScrollingPreviewView(image: nil))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        self.hosting = hosting

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver + 2  // 高于遮罩，别被压暗
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        let screen = NSScreen.screens.first { $0.frame.intersects(selectionRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var originX = selectionRect.maxX + Self.gap
        if originX + Self.size.width > visible.maxX {
            originX = selectionRect.minX - Self.size.width - Self.gap
        }
        originX = min(max(originX, visible.minX + 8), visible.maxX - Self.size.width - 8)
        let originY = min(
            max(selectionRect.maxY - Self.size.height, visible.minY + 8),
            visible.maxY - Self.size.height - 8
        )
        panel.setFrame(
            NSRect(origin: CGPoint(x: originX, y: originY), size: Self.size), display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(image: CGImage) {
        hosting?.rootView = ScrollingPreviewView(image: Self.thumbnail(image))
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    /// 降采样到预览窗两倍像素以内：预览只有 124×408，原图交给 SwiftUI 太贵。
    private static func thumbnail(_ image: CGImage) -> NSImage {
        let maxWidth = Self.size.width * 2
        let maxHeight = Self.size.height * 2
        let scale = min(
            1,
            min(maxWidth / CGFloat(image.width), maxHeight / CGFloat(image.height))
        )
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        return NSImage(cgImage: scaled, size: NSSize(width: width, height: height))
    }
}

/// 预览窗内容：一张按比例缩放到窗口内的长图，顶部对齐。
///
/// @author ixxxxoooo
struct ScrollingPreviewView: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                // 画的图与这块内容区同比例（见 `previewPixelSize`），所以 `.fit` 正好铺满；
                // 保留比例这一条不能省：万一拿到的是别的比例的图（兜底路径给的是整张长图），
                // `.resizable()` 直接铺满会把它**拉变形**——用户看到的"预览拉伸"就是它。
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Text(L10n.scrollPanelWaiting)
                    .font(Theme.Typography.rowSubtitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Theme.Spacing.xs)
        .floatingSurface(cornerRadius: Theme.Radius.card)
    }
}
