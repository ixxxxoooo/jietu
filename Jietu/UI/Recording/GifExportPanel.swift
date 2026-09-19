import AppKit

/// GIF 导出期间的进度浮窗。
///
/// 转一份 GIF 要解码整段视频（几秒到几十秒），没有反馈用户只会以为点坏了——
/// 和「识别文字首次要装模型」是同一类问题，所以这里给一条带百分比的浮窗。
/// 不抢焦点（`nonactivatingPanel`），导出完自己收掉。
///
/// @author ixxxxoooo
@MainActor
final class GifExportPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "正在导出 GIF…")
    private let bar = NSProgressIndicator()

    private static let size = CGSize(width: 260, height: 72)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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
        label.lineBreakMode = .byTruncatingMiddle

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.controlSize = .small

        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Theme.Spacing.lg),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -Theme.Spacing.lg),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = effect
    }

    /// 浮到指定屏幕中央（不激活 App，也不抢焦点）。
    func present(on screen: NSScreen?) {
        let target = screen ?? NSScreen.main
        if let frame = target?.visibleFrame {
            panel.setFrame(
                NSRect(
                    x: frame.midX - Self.size.width / 2,
                    y: frame.midY - Self.size.height / 2,
                    width: Self.size.width, height: Self.size.height
                ),
                display: false
            )
        }
        panel.orderFrontRegardless()
    }

    func update(fraction: Double) {
        let clamped = min(1, max(0, fraction))
        bar.doubleValue = clamped
        label.stringValue = "正在导出 GIF… \(Int((clamped * 100).rounded()))%"
    }

    func close() {
        panel.orderOut(nil)
    }
}
