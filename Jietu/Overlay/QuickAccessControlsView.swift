import AppKit
import SwiftUI

/// 浮窗上的动作。
///
/// 两种卡片各用一套，位子是固定的（见 `slot`）：
/// - **图片卡**：四角 + 中央「保存」胶囊（截图还没落盘，「保存」是主操作）；
/// - **视频卡**：只有四角（录屏一收工文件就已经在保存目录里了，没有「保存」这回事）。
///
/// @author ixxxxoooo
enum QuickAccessAction: String, CaseIterable {
    // 图片卡
    case close, pin, annotate, copy, save
    // 视频卡（录屏收工）
    case play, reveal, copyFile

    /// 图片卡的动作与摆位：左上复制 / 右上关闭 / 左下标注 / 右下钉图 / 中央保存。
    static let imageCard: [QuickAccessAction] = [.copy, .close, .annotate, .pin, .save]
    /// 视频卡的动作与摆位：左上复制文件 / 右上关闭 / 左下播放 / 右下在访达中显示。
    static let videoCard: [QuickAccessAction] = [.copyFile, .close, .play, .reveal]

    /// 控件在卡片里的位子。写死在这里，`frame(of:in:)` 与自检都按它算注入点。
    enum Slot {
        case topLeft, topRight, bottomLeft, bottomRight, center
    }

    var slot: Slot {
        switch self {
        case .copy, .copyFile: .topLeft
        case .close: .topRight
        case .annotate, .play: .bottomLeft
        case .pin, .reveal: .bottomRight
        case .save: .center
        }
    }

    var symbol: String {
        switch self {
        case .close: "xmark"
        case .pin: "pin"
        case .annotate: "pencil.tip.crop.circle"
        case .copy, .copyFile: "doc.on.doc"
        case .save: "square.and.arrow.down"
        case .play: "play.fill"
        case .reveal: "folder"
        }
    }

    var title: String {
        switch self {
        case .close: "关闭"
        case .pin: "钉图"
        case .annotate: "标注"
        case .copy: "复制"
        case .save: "保存"
        case .play: "播放"
        case .reveal: "在访达中显示"
        case .copyFile: "复制文件"
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
        switch action.slot {
        case .topRight:
            nominal = CGPoint(x: cardSize.width - inset - radius, y: cardSize.height - inset - radius)
        case .bottomRight:
            nominal = CGPoint(x: cardSize.width - inset - radius, y: inset + radius)
        case .bottomLeft:
            nominal = CGPoint(x: inset + radius, y: inset + radius)
        case .topLeft:
            nominal = CGPoint(x: inset + radius, y: cardSize.height - inset - radius)
        case .center:
            nominal = CGPoint(x: cardSize.width / 2, y: cardSize.height / 2)
        }

        /// 把矩形夹进卡片：卡片够大就贴边收进去，卡片比控件还小就居中（对称溢出，
        /// 至少还看得见、点得到），总之不能把按钮整块推到卡片外面去。
        func clamp(_ value: CGFloat, in extent: CGFloat, size size: CGFloat) -> CGFloat {
            guard extent > size else { return ((extent - size) / 2).rounded() }
            return min(max(value, 0), extent - size).rounded()
        }

        return NSRect(
            x: clamp(nominal.x - size.width / 2, in: cardSize.width, size: size.width),
            y: clamp(nominal.y - size.height / 2, in: cardSize.height, size: size.height),
            width: size.width,
            height: size.height
        )
    }

    /// - Parameter actions: 这张卡片要摆哪些动作（默认图片卡那五个）。
    init(actions: [QuickAccessAction] = QuickAccessAction.imageCard) {
        super.init(frame: .zero)
        wantsLayer = true
        for action in actions {
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

    /// 只有按钮自己吃事件；其余位置让给下层 SwiftUI（点击进标注、拖拽导出）。
    ///
    /// 静息态（没悬停）也整层放行：图标还没浮出来时，整张卡片就是截图本身，
    /// 这一下该落到「点击进标注 / 拖拽导出」上，而不是被五个看不见的按钮拦下来。
    /// 「甩过去就点」那种快点由 tracking 保证——`mouseEntered` 在 `mouseDown` 的命中测试
    /// 之前就已派发（自检里有一条专门量它：不等悬停直接点关闭，必须点掉而不是点成标注）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard isHovering, bounds.contains(local) else { return nil }
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
    var actions: [QuickAccessAction] = QuickAccessAction.imageCard
    var onAction: (QuickAccessAction) -> Void
    var onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> QuickAccessControlsView {
        let view = QuickAccessControlsView(actions: actions)
        view.onAction = onAction
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ view: QuickAccessControlsView, context: Context) {
        view.onAction = onAction
        view.onHoverChange = onHoverChange
    }
}
