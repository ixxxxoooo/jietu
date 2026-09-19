import AppKit

/// 一条自动消失的提示浮窗：不抢焦点、不打断，只说一句「做完了」。
///
/// 取色器要用它：系统放大镜一收，用户没法确认到底复制到没有，得有个回执。
/// 表面沿用设计系统那一套（`.hudWindow` + `.withinWindow`，与录屏控制条、GIF 进度浮窗同一配方），
/// 位置贴着刚才操作的地方（鼠标），别让人满屏找。
///
/// @author ixxxxoooo
@MainActor
final class ToastPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let swatch = NSView()
    private let stack = NSStackView()
    private var dismissTask: Task<Void, Never>?

    private static let swatchSide: CGFloat = 14
    private static let padding = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.Radius.menuPanel
        effect.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 4
        swatch.layer?.borderWidth = Theme.Size.hairline
        swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Theme.Spacing.sm
        stack.addArrangedSubview(swatch)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: Self.swatchSide),
            swatch.heightAnchor.constraint(equalToConstant: Self.swatchSide),
            stack.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            stack.leadingAnchor.constraint(
                equalTo: effect.leadingAnchor, constant: Self.padding.left),
            stack.trailingAnchor.constraint(
                equalTo: effect.trailingAnchor, constant: -Self.padding.right),
        ])
        panel.contentView = effect
    }

    /// 弹一条提示，`duration` 秒后自己收掉。
    ///
    /// - Parameters:
    ///   - swatchColor: 想带一枚色块就传（取色回执用），传 nil 就只显示文字。
    ///   - point: 贴着这个屏幕坐标显示（一般传 `NSEvent.mouseLocation`）；nil 则落在鼠标所在屏正中。
    func present(
        _ text: String,
        swatchColor: NSColor? = nil,
        near point: NSPoint? = nil,
        duration: TimeInterval = 1.6
    ) {
        label.stringValue = text
        if let swatchColor, let srgb = swatchColor.usingColorSpace(.sRGB) {
            swatch.isHidden = false
            swatch.layer?.backgroundColor = srgb.cgColor
        } else {
            swatch.isHidden = true
        }

        let content = stack.fittingSize
        let size = NSSize(
            width: max(content.width, Self.swatchSide) + Self.padding.left + Self.padding.right,
            height: content.height + Self.padding.top + Self.padding.bottom
        )
        panel.setFrame(NSRect(origin: origin(for: size, near: point), size: size), display: false)
        panel.orderFrontRegardless()

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }

    /// 提示落在哪：贴着 `point` 下方（光标下面一点），并夹进那块屏的可见区域。
    private func origin(for size: NSSize, near point: NSPoint?) -> NSPoint {
        let screen = point.flatMap { target in
            NSScreen.screens.first { $0.frame.contains(target) }
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = point ?? NSPoint(x: visible.midX, y: visible.midY)
        let gap: CGFloat = 22
        let x = min(max(anchor.x - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        // 光标下面放不下（贴着屏幕底）就翻到光标上方。
        var y = anchor.y - gap - size.height
        if y < visible.minY + 8 {
            y = min(anchor.y + gap, visible.maxY - size.height - 8)
        }
        return NSPoint(x: x, y: y)
    }
}
