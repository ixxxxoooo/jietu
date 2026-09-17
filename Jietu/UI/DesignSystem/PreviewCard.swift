import AppKit
import SwiftUI

/// 「预览卡片」——钉图与浮窗共用的外框，对齐 macOS 自己那个截图预览窗口的样子：
///
/// - 截图**不贴边**，外面留一圈窄外框（`inset`）；
/// - 外框大圆角（`cornerRadius`），截图自己小一档圆角（`contentRadius`）；
/// - 外框是浮在桌面上的玻璃 + 一条发丝描边，阴影交给系统窗口阴影。
///
/// 两个表面共用这一套数字，别再各写一份——「钉图和浮窗长得像」全靠这里。
///
/// @author ixxxxoooo
enum PreviewCard {
    /// 截图与外框之间的留白。
    static let inset = Theme.Size.previewCardInset
    /// 外框圆角。
    static let cornerRadius = Theme.Radius.previewCard
    /// 截图自己的圆角。
    static let contentRadius = Theme.Radius.previewContent

    /// 截图在外框里的矩形（AppKit 坐标：原点左下）。
    static func contentRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: inset, dy: inset)
    }

    /// 卡片尺寸 = 截图尺寸 + 两边外框。
    static func cardSize(forContent content: CGSize) -> CGSize {
        CGSize(width: content.width + inset * 2, height: content.height + inset * 2)
    }
}

extension NSColor {
    /// 卡片描边，与 `Theme.Colors.cardStroke` 同源。
    static let jietuCardStroke = NSColor(name: nil) { appearance in
        appearance.isDark ? .srgbInk(1, alpha: 0.10) : .srgbInk(0, alpha: 0.10)
    }
}

/// 只画一圈圆角描边的视图（`layer.borderWidth`，不走 `draw`）。
///
/// 描边色是自适应墨色，`updateLayer` 在换外观时会重来一次。
///
/// @author ixxxxoooo
final class CardBorderView: NSView {
    var borderColor: NSColor = .jietuCardStroke { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Theme.Size.hairline
        layer?.borderColor = borderColor.cgColor
        layer?.masksToBounds = false
    }
}

/// 预览卡片的底板（AppKit 侧）：系统玻璃 + 发丝描边。
///
/// 与 `Theme.glassPanel` / `GlassControlButton` 同配方（`.regular` 玻璃 + `glassFrost` 色调），
/// 所以钉图的外框、浮窗的卡片、卡片上的图标按钮是同一套材质。
///
/// @author ixxxxoooo
final class PreviewCardChrome: NSView {
    private let glass = NSGlassEffectView()
    private let border = CardBorderView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        glass.style = .regular
        glass.tintColor = NSColor(name: nil) { $0.isDark
            ? .srgbInk(1, alpha: 0.05)
            : .srgbInk(1, alpha: 0.25)
        }
        addSubview(glass)
        addSubview(border)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = PreviewCard.cornerRadius
        border.frame = bounds
        border.cornerRadius = PreviewCard.cornerRadius
        border.needsDisplay = true
    }
}

extension View {
    /// 预览卡片的描边（SwiftUI 侧，配合 `glassPanel` 用）。
    func previewCardBorder(cornerRadius: CGFloat = PreviewCard.cornerRadius) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.Colors.cardStroke, lineWidth: Theme.Size.hairline)
        }
    }
}
