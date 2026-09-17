import AppKit

/// 录屏控制条：红点 + 已录时长 + 暂停/继续 + 停止 + 取消，贴着选区下方浮着。
///
/// 为什么是 AppKit 而不是 SwiftUI：这是**非激活面板**（不抢前台，录制时用户还要操作别的 App），
/// 而 SwiftUI 的 Button 在这种窗口上首击可能被用来激活窗口（要按两下）。
/// 这里用设计系统的 `GlassControlButton`（`acceptsFirstMouse = true`），一下就是一下。
///
/// @author ixxxxoooo
@MainActor
final class RecordingControlPanel {
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private var content: RecordingControlContentView?

    /// 给录制排除用：控制条不能出现在成片里。
    var windowNumber: Int? { panel.map { $0.windowNumber } }
    var isVisible: Bool { panel?.isVisible ?? false }

    private static let size = CGSize(width: 208, height: 44)

    /// 贴着选区下方展示（下方放不下就挪到上方）。
    func present(near selectionRect: CGRect, in screen: NSScreen?) {
        close()

        let content = RecordingControlContentView(frame: NSRect(origin: .zero, size: Self.size))
        content.onTogglePause = { [weak self] in self?.onTogglePause?() }
        content.onStop = { [weak self] in self?.onStop?() }
        content.onCancel = { [weak self] in self?.onCancel?() }
        self.content = content

        let panel = NSPanel(
            contentRect: NSRect(origin: origin(for: selectionRect, in: screen), size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar + 2
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // 控制条要能拖开（挡住内容时）：背景拖动移动窗口，按钮自己吃自己的点击。
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = content
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// 已录秒数（mm:ss）。
    func update(elapsed: TimeInterval) {
        content?.setElapsed(elapsed)
    }

    func setPaused(_ paused: Bool) {
        content?.setPaused(paused)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        content = nil
    }

    /// 默认贴在选区下方 8pt；下方不够就翻到上方；左右夹进屏幕。
    private func origin(for selectionRect: CGRect, in screen: NSScreen?) -> CGPoint {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var y = selectionRect.minY - Self.size.height - 8
        if y < visible.minY + 4 {
            y = selectionRect.maxY + 8
        }
        y = min(max(y, visible.minY + 4), visible.maxY - Self.size.height - 4)
        let x = min(
            max(selectionRect.midX - Self.size.width / 2, visible.minX + 4),
            visible.maxX - Self.size.width - 4
        )
        return CGPoint(x: x, y: y)
    }
}

/// 控制条的内容视图：玻璃圆角 + 红点 + 时长 + 三个按钮。
///
/// @author ixxxxoooo
private final class RecordingControlContentView: NSView {
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private let glass = NSVisualEffectView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "00:00")
    private lazy var pauseButton = GlassControlButton(
        symbol: "pause.fill", diameter: 26, tooltip: "暂停 (⌘⇧P)"
    )
    private let stopButton = GlassControlButton(
        symbol: "stop.fill", diameter: 26, tooltip: "完成 (⌘⇧S)",
        iconTint: NSColor(Theme.Colors.destructive)
    )
    private let cancelButton = GlassControlButton(
        symbol: "xmark", diameter: 26, tooltip: "取消（不保存）"
    )
    private var isPaused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = Theme.Radius.dialog
        glass.layer?.masksToBounds = true
        addSubview(glass)

        // 红点：录制中一直亮着，暂停时压暗——一眼能看出状态。
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(Theme.Colors.destructive).cgColor
        dot.layer?.cornerRadius = 4
        addSubview(dot)

        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor(name: nil) { $0.isDark ? .srgbInk(1, alpha: 1) : .srgbInk(0, alpha: 1) }
        label.alignment = .left
        addSubview(label)

        pauseButton.onClick = { [weak self] in self?.onTogglePause?() }
        stopButton.onClick = { [weak self] in self?.onStop?() }
        cancelButton.onClick = { [weak self] in self?.onCancel?() }
        for button in [pauseButton, stopButton, cancelButton] {
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let mid = bounds.midY
        dot.frame = NSRect(x: 14, y: mid - 4, width: 8, height: 8)
        label.sizeToFit()
        label.frame = NSRect(
            x: dot.frame.maxX + 8, y: mid - label.frame.height / 2,
            width: 46, height: label.frame.height
        )
        var x = bounds.maxX - 12 - 26
        for button in [cancelButton, stopButton, pauseButton] {
            button.frame = NSRect(x: x, y: mid - 13, width: 26, height: 26)
            x -= 26 + 6
        }
    }

    func setElapsed(_ elapsed: TimeInterval) {
        let total = max(0, Int(elapsed.rounded(.down)))
        label.stringValue = String(format: "%02d:%02d", total / 60, total % 60)
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        pauseButton.symbolName = paused ? "play.fill" : "pause.fill"
        pauseButton.toolTip = paused ? "继续 (⌘⇧P)" : "暂停 (⌘⇧P)"
        dot.layer?.backgroundColor = NSColor(Theme.Colors.destructive)
            .withAlphaComponent(paused ? 0.35 : 1).cgColor
    }
}
