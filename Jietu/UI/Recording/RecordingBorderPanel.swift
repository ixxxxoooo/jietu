import AppKit

/// 录制区域的红框：告诉用户「正在录这一块」。
///
/// 非交互（`ignoresMouseEvents`），并且会被录制排除掉（`excludingWindowNumbers`），
/// 所以它压在区域边缘也不会被拍进成片。
///
/// @author ixxxxoooo
@MainActor
final class RecordingBorderPanel {
    private var panel: NSPanel?

    var windowNumber: Int? { panel.map { $0.windowNumber } }
    var isVisible: Bool { panel?.isVisible ?? false }

    private static let lineWidth: CGFloat = 2

    /// 贴着一块区域画框（AppKit 全局坐标）。
    func present(around regionRect: CGRect) {
        close()
        let rect = regionRect.insetBy(dx: -Self.lineWidth, dy: -Self.lineWidth)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar + 1
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = BorderView(
            frame: NSRect(origin: .zero, size: rect.size), lineWidth: Self.lineWidth
        )
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// 只画一圈红线，别的什么都不画。
    private final class BorderView: NSView {
        private let lineWidth: CGFloat

        init(frame: NSRect, lineWidth: CGFloat) {
            self.lineWidth = lineWidth
            super.init(frame: frame)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draw(_ dirtyRect: NSRect) {
            let inset = lineWidth / 2
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset),
                xRadius: 4,
                yRadius: 4
            )
            path.lineWidth = lineWidth
            NSColor(Theme.Colors.destructive).setStroke()
            path.stroke()
        }
    }
}
