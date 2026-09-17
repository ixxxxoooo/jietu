import AppKit
import QuartzCore

/// 悬停高亮层：用 layer 直接填色。
///
/// 不能用 `NSBox` —— 它的 `fillColor` 走的是自己那套绘制，放进
/// `NSGlassEffectView.contentView` 里**完全不渲染**（悬停看不到任何反馈）。
///
/// @author ixxxxoooo
final class HoverTintView: NSView {
    var tintColor: NSColor = .clear
    var cornerRadius: CGFloat = 0

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = tintColor.cgColor
        layer?.cornerRadius = cornerRadius
    }
}

/// 玻璃浮动按钮：**钉图与浮窗共用**的一套图标按钮。
///
/// - `.circle`：圆盘 + 单个图标（钉图右上关闭 / 右下实况文本、浮窗四角）；
/// - `.capsule`：胶囊 + 图标 + 文字（浮窗中央的「保存」）。
///
/// 两种外形的交互配方完全一致——这正是「浮窗上的图标看着、点着都和钉图一个手感」的前提：
/// - 底层 `NSGlassEffectView(.regular)` + `glassFrost` 色调，跟随系统外观；
/// - 悬停压一层 `menuHover` 墨（0.12s ease-out）；
/// - **按下即时反馈**：`mouseDown` 当场缩放 0.85 + 压暗到 0.75（0.08s），不等 `mouseUp`。
///   用户感知的「灵敏」主要来自这一下——动作在抬起时发生是常规，但视觉不能等到抬起；
/// - `acceptsFirstMouse`：面板不是 key window 时**第一下点击直接生效**，
///   不用「先点一下激活窗口、再点一下操作」。非激活浮窗最容易在这里显得迟钝。
///
/// @author ixxxxoooo
final class GlassControlButton: NSControl {
    var onClick: (() -> Void)?

    /// 开关型按钮（钉图的实况文本）点开后的样子：图标换成**居中的绿色对勾**。
    /// 不用角标——28pt 的圆盘上角标又小又偏，勾在正中间才对得上「已生效」。
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            updateIcon()
        }
    }

    private let symbolName: String
    private let labelText: String?
    private let diameter: CGFloat

    /// 当前实际画出来的符号（点亮后是 `checkmark`），测试用。
    private var currentSymbolName = ""

    private let glassView = NSGlassEffectView()
    private let glassContainer = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hoverOverlay = HoverTintView()
    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    /// 图标槽：圆形按钮里是居中一块，胶囊里是文字左边一块。
    private static let iconSlot: CGFloat = 16
    /// 胶囊高度与工具条控件同档，两种外形放一起才不打架。
    private static let capsuleHeight = Theme.Size.barButtonHeight
    private static let labelFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    /// 图标与文字同为 `textPrimary`：深色白墨、浅色黑墨。
    private static let inkColor = NSColor(name: nil) { $0.isDark
        ? .srgbInk(1, alpha: 1)
        : .srgbInk(0, alpha: 1)
    }

    /// 尺寸是纯函数（自检 / 单测要按它算注入点，所以不能藏在 layout 里）。
    static func preferredSize(diameter: CGFloat = 28, labelText: String? = nil) -> NSSize {
        guard let labelText, !labelText.isEmpty else {
            return NSSize(width: diameter, height: diameter)
        }
        let text = (labelText as NSString).size(withAttributes: [.font: labelFont]).width
        return NSSize(
            width: (Theme.Spacing.xl + iconSlot + Theme.Spacing.sm + text.rounded(.up)
                + Theme.Spacing.xl).rounded(),
            height: capsuleHeight
        )
    }

    init(symbol: String, labelText: String? = nil, diameter: CGFloat = 28, tooltip: String) {
        self.symbolName = symbol
        self.labelText = labelText
        self.diameter = diameter
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize(
            diameter: diameter, labelText: labelText
        )))
        wantsLayer = true
        toolTip = tooltip

        // 1. 系统自适应玻璃：与 `Theme.frosted` / `glassPanel` 同配方（`.regular` + glassFrost 色调）
        glassView.style = .regular
        glassView.tintColor = NSColor(name: nil) { $0.isDark
            ? .srgbInk(1, alpha: 0.05)
            : .srgbInk(1, alpha: 0.25)
        }
        addSubview(glassView)

        // `NSGlassEffectView` 只保证 `contentView` 的层级；悬停层与图标必须放进去，
        // 否则会被玻璃盖住（悬停看不到任何反馈）。
        glassContainer.wantsLayer = true
        glassView.contentView = glassContainer

        // 2. 悬停微光高亮层（ramp 的 menuHover）
        hoverOverlay.tintColor = NSColor(name: nil) { $0.isDark
            ? .srgbInk(1, alpha: 0.10)
            : .srgbInk(0, alpha: 0.09)
        }
        hoverOverlay.alphaValue = 0
        hoverOverlay.wantsLayer = true
        glassContainer.addSubview(hoverOverlay)

        // 3. 图标（SF Symbol，未点亮走 alpha ramp 的 textPrimary；点亮换成绿勾）
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        glassContainer.addSubview(iconView)
        updateIcon()

        // 4. 胶囊的文字（圆盘不用）
        titleLabel.font = Self.labelFont
        titleLabel.textColor = Self.inkColor
        titleLabel.alignment = .left
        titleLabel.isHidden = labelText == nil
        glassContainer.addSubview(titleLabel)

        // 5. 原生柔和投影，增强玻璃浮空通透感（白底图上也要能把按钮「托」出来）
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow?.shadowOffset = NSSize(width: 0, height: -1)
        shadow?.shadowBlurRadius = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 未点亮：原形图标 + `textPrimary`；点亮：居中的绿色对勾（功能色 `success`）。
    private func updateIcon() {
        let symbol = isActive ? "checkmark" : symbolName
        // 勾单独放大了才不显小（原图标四周有留白，勾是满格的）。
        let config = NSImage.SymbolConfiguration(
            pointSize: isActive ? 13 : 12,
            weight: .semibold
        )
        currentSymbolName = symbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config)
        iconView.image = image
        iconView.contentTintColor = isActive ? NSColor(Theme.Colors.success) : Self.inkColor
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        return self
    }

    override func layout() {
        super.layout()
        glassView.frame = bounds
        glassView.cornerRadius = labelText == nil ? bounds.width / 2 : bounds.height / 2
        glassContainer.frame = glassView.bounds
        hoverOverlay.frame = glassContainer.bounds
        hoverOverlay.cornerRadius = glassView.cornerRadius
        hoverOverlay.needsDisplay = true

        let center = CGPoint(x: glassContainer.bounds.midX, y: glassContainer.bounds.midY)
        if let labelText, !labelText.isEmpty {
            // 胶囊：图标 + 文字整体居中（先按文字实际宽度求整体宽度，再摆两块）。
            titleLabel.font = Self.labelFont
            titleLabel.sizeToFit()
            let labelSize = titleLabel.frame.size
            let contentWidth = Self.iconSlot + Theme.Spacing.sm + labelSize.width
            let originX = center.x - contentWidth / 2
            iconView.frame = NSRect(
                x: originX, y: center.y - Self.iconSlot / 2,
                width: Self.iconSlot, height: Self.iconSlot
            )
            titleLabel.frame = NSRect(
                x: iconView.frame.maxX + Theme.Spacing.sm, y: center.y - labelSize.height / 2,
                width: labelSize.width, height: labelSize.height
            )
        } else {
            iconView.frame = NSRect(
                x: center.x - Self.iconSlot / 2, y: center.y - Self.iconSlot / 2,
                width: Self.iconSlot, height: Self.iconSlot
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// 由宿主统一驱动：宿主的 tracking 已经确认可靠（按钮就是靠它唤出的），
    /// 按钮自己的 tracking area 在隐藏→显示切换后不一定会重建。
    func setHovering(_ hovering: Bool) {
        guard isHovered != hovering else { return }
        isHovered = hovering
        animateHover(highlighted: hovering)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
        isPressed = false
        animatePress(pressed: false)
    }

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        InteractionMetrics.record(
            name: metricsName, phase: .feedback, eventTimestamp: event.timestamp
        )
        #endif
        isPressed = true
        animatePress(pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        animatePress(pressed: false)

        let point = convert(event.locationInWindow, from: nil)
        guard wasPressed, bounds.contains(point) else { return }
        #if DEBUG
        InteractionMetrics.record(
            name: metricsName, phase: .action, eventTimestamp: event.timestamp
        )
        #endif
        onClick?()
    }

    private func animateHover(highlighted: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Duration.hover
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverOverlay.animator().alphaValue = highlighted ? 1.0 : 0.0
        }
    }

    private func animatePress(pressed: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = pressed ? 0.08 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glassView.animator().alphaValue = pressed ? 0.75 : 1.0
            iconView.animator().alphaValue = pressed ? 0.75 : 1.0
            titleLabel.animator().alphaValue = pressed ? 0.75 : 1.0
        }

        guard let layer else { return }
        let from = layer.presentation()?.transform ?? layer.transform
        let to = pressed
            ? CATransform3DMakeScale(0.85, 0.85, 1)
            : CATransform3DIdentity
        layer.transform = to

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = pressed ? 0.08 : 0.18
        animation.timingFunction = CAMediaTimingFunction(
            name: pressed ? .easeOut : .easeInEaseOut
        )
        layer.add(animation, forKey: "pressScale")
    }

    /// 量测里的名字：提示语最像人话（「关闭」「钉图」），退到文字、符号名。
    private var metricsName: String { toolTip ?? labelText ?? symbolName }

    // MARK: - 测试钩子

    /// 测试用：按钮底是否**跟随系统外观**（不再强制深色）。
    var followsSystemAppearance: Bool {
        glassView.appearance == nil && glassView.style == .regular
    }

    /// 测试用：当前画出来的符号名（点亮后应为 `checkmark`）。
    var renderedSymbolName: String { currentSymbolName }

    /// 测试用：当前图标颜色。
    var renderedIconTint: NSColor? { iconView.contentTintColor }

    /// 测试用：是否处于按下态（按下反馈应当**当场**就位，不等抬起）。
    var isPressedNow: Bool { isPressed }

    /// 测试用：悬停墨层的不透明度（0 = 没悬停，1 = 悬停到位）。
    var hoverTintAlpha: CGFloat { hoverOverlay.alphaValue }
}
