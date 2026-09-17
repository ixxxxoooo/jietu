import AppKit
import SwiftUI

/// 浮窗上的 5 个动作。
///
/// @author ixxxxoooo
enum QuickAccessAction: String, CaseIterable {
    case close, pin, annotate, copy, save

    var symbol: String {
        switch self {
        case .close: "xmark"
        case .pin: "pin"
        case .annotate: "pencil.tip.crop.circle"
        case .copy: "doc.on.doc"
        case .save: "square.and.arrow.down"
        }
    }

    var title: String {
        switch self {
        case .close: "关闭"
        case .pin: "钉图"
        case .annotate: "标注"
        case .copy: "复制"
        case .save: "保存"
        }
    }

    /// 四角是圆盘图标；中央的「保存」是胶囊（图标 + 文字，它是主操作）。
    var isCircle: Bool { self != .save }
}

/// 浮窗的图标层：**与钉图共用 `GlassControlButton`**，所以两边看着、点着都是同一套手感
/// （同款系统玻璃、同款悬停微光、同款按下缩放、同款「首击即生效」）。
///
/// 为什么这一层是 AppKit 而不是几行 SwiftUI：浮窗是 `nonactivatingPanel`，窗口通常不是
/// key window，SwiftUI 的 `Button` 在这种窗口上第一下点击有可能只被用来激活窗口；
/// 而 `GlassControlButton` 用 `acceptsFirstMouse` + `mouseDown` 当场反馈，保证「瞄过去点一下
/// 就生效」——用户说的「灵敏」就是这一下。
///
/// 事件归属：**只有按钮自己吃事件**，卡片其余位置一律返回 nil 让给下层 SwiftUI
/// （点击进标注、拖拽导出照旧）。因此按钮不能常驻吃事件，否则四角的拖拽导出会变死区。
///
/// @author ixxxxoooo
final class QuickAccessControlsView: NSView {
    /// 圆盘直径。与钉图的两个按钮同尺寸——同一套图标系统，不该差一档。
    static let diameter: CGFloat = 28
    /// 按钮**边缘**离卡片边缘的距离（钉图同为 8pt）。
    static let edgeInset: CGFloat = Theme.Spacing.md

    var onAction: ((QuickAccessAction) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    private(set) var isHovering = false
    private var buttons: [(action: QuickAccessAction, button: GlassControlButton)] = []
    private var trackingArea: NSTrackingArea?

    /// 每个动作在卡片坐标系（原点**左下**，与 AppKit 一致）里该占的矩形。
    ///
    /// 写成纯函数是为了让自检 / 单测按**同一套**几何算注入点，而不是各自抄一遍边距。
    /// 超宽截图换算出来只有十几点高的扁卡片里，按钮会被夹回卡片内——宁可挤在一起，
    /// 也不能画到卡片外面去（那样按钮就点不到了）。
    static func frame(of action: QuickAccessAction, in cardSize: CGSize) -> NSRect {
        let size = GlassControlButton.preferredSize(
            diameter: diameter, labelText: action.isCircle ? nil : action.title
        )
        let radius = diameter / 2
        let inset = edgeInset
        let nominal: CGPoint
        switch action {
        case .close:
            nominal = CGPoint(x: cardSize.width - inset - radius, y: cardSize.height - inset - radius)
        case .pin:
            nominal = CGPoint(x: cardSize.width - inset - radius, y: inset + radius)
        case .annotate:
            nominal = CGPoint(x: inset + radius, y: inset + radius)
        case .copy:
            nominal = CGPoint(x: inset + radius, y: cardSize.height - inset - radius)
        case .save:
            nominal = CGPoint(x: cardSize.width / 2, y: cardSize.height / 2)
        }

        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let minX = min(halfWidth, cardSize.width / 2)
        let minY = min(halfHeight, cardSize.height / 2)
        let center = CGPoint(
            x: min(max(nominal.x, minX), max(cardSize.width - minX, minX)),
            y: min(max(nominal.y, minY), max(cardSize.height - minY, minY))
        )
        return NSRect(
            x: (center.x - halfWidth).rounded(),
            y: (center.y - halfHeight).rounded(),
            width: size.width,
            height: size.height
        )
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for action in QuickAccessAction.allCases {
            let button = GlassControlButton(
                symbol: action.symbol,
                labelText: action.isCircle ? nil : action.title,
                diameter: Self.diameter,
                tooltip: action.title
            )
            button.onClick = { [weak self] in self?.onAction?(action) }
            // 静息态不显示（但仍在层级里，命中与否由 `hitTest` 按悬停放行）。
            button.alphaValue = 0
            addSubview(button)
            buttons.append((action, button))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        for (action, button) in buttons {
            button.frame = Self.frame(of: action, in: bounds.size)
        }
        // 叠放的浮窗 / 光标下的浮窗出现时没有 mouseEntered 可等，这里按当前光标补一次。
        refreshHoverFromMouseLocation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHoverFromMouseLocation()
    }

    /// 只有按钮自己吃事件；其余位置让给下层。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHovering, bounds.contains(point) else { return nil }
        return super.hitTest(point) as? GlassControlButton
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
        for (_, button) in buttons { button.setHovering(false) }
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Duration.hover
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for (_, button) in buttons {
                button.animator().alphaValue = hovering ? 1 : 0
            }
        }
        onHoverChange?(hovering)
    }

    /// 无窗口（构造期 / 测试）时保持原状。
    private func refreshHoverFromMouseLocation() {
        guard let window else { return }
        let inWindow = window.convertFromScreen(
            NSRect(origin: NSEvent.mouseLocation, size: .zero)
        ).origin
        setHovering(bounds.contains(convert(inWindow, from: nil)))
    }

    // MARK: - 测试钩子

    /// 测试用：某个动作的按钮。
    func button(for action: QuickAccessAction) -> GlassControlButton? {
        buttons.first { $0.action == action }?.button
    }
}

/// 把浮窗图标层塞进 SwiftUI 卡片。
///
/// @author ixxxxoooo
struct QuickAccessControlLayer: NSViewRepresentable {
    var onAction: (QuickAccessAction) -> Void
    var onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> QuickAccessControlsView {
        let view = QuickAccessControlsView()
        view.onAction = onAction
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ view: QuickAccessControlsView, context: Context) {
        view.onAction = onAction
        view.onHoverChange = onHoverChange
    }
}
