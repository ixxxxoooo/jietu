import AppKit

/// 录屏控制条：**先停在「待开始」**，点「开始」才真开录；录制中红点 + 已录时长 + 暂停/继续 + 完成 + 取消。
///
/// 不选完区域就自动开录：录屏是「先把框摆好再决定」，自动开录会把用户还没准备好的那几秒也录进去
/// （滚动长图那边也是同一套路：先停在待开始态）。
///
/// 为什么是 AppKit 而不是 SwiftUI：这是**非激活面板**（不抢前台，录制时用户还要操作别的 App），
/// 而 SwiftUI 的 Button 在这种窗口上首击可能被用来激活窗口（要按两下）。
/// 这里用设计系统的 `GlassControlButton`（`acceptsFirstMouse = true`），一下就是一下。
///
/// @author ixxxxoooo
@MainActor
final class RecordingControlPanel {
    /// 控制条的两个阶段。
    enum Phase {
        /// 框已选好、还没开录：`[●] 准备录制  [取消] [开始]`。
        case ready
        /// 正在录：`[★] 00:12  [取消] [完成] [暂停]`。
        case recording
    }

    var onStart: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private var content: RecordingControlContentView?

    /// 给录制排除用：控制条不能出现在成片里。
    var windowNumber: Int? { panel.map { $0.windowNumber } }
    var isVisible: Bool { panel?.isVisible ?? false }

    private static let size = CGSize(width: 216, height: 44)

    /// 贴着选区下方展示（下方放不下就挪到上方）。
    func present(near selectionRect: CGRect, in screen: NSScreen?, phase: Phase = .ready) {
        close()

        let content = RecordingControlContentView(frame: NSRect(origin: .zero, size: Self.size))
        content.onStart = { [weak self] in self?.onStart?() }
        content.onTogglePause = { [weak self] in self?.onTogglePause?() }
        content.onStop = { [weak self] in self?.onStop?() }
        content.onCancel = { [weak self] in self?.onCancel?() }
        content.setPhase(phase)
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

    /// 切阶段（待开始 → 录制中）。
    func setPhase(_ phase: Phase) {
        content?.setPhase(phase)
    }

    /// 自检用：某个按钮在屏幕上的矩形（注入点击要按它算点）。
    enum TestingButton { case start, pause, stop, cancel }

    func screenFrame(of button: TestingButton) -> CGRect? {
        guard let content, let panel else { return nil }
        let local: NSRect?
        switch button {
        case .start: local = content.startFrame
        case .pause: local = content.pauseFrame
        case .stop: local = content.stopFrame
        case .cancel: local = content.cancelFrame
        }
        guard let local else { return nil }
        return panel.convertToScreen(content.convert(local, to: nil))
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

/// 控制条的内容视图：玻璃圆角 + 红点 + （准备录制 / 已录时长）+ 按钮。
///
/// @author ixxxxoooo
private final class RecordingControlContentView: NSView {
    var onStart: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private let glass = NSVisualEffectView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "准备录制")
    /// 「开始」：待开始态的主操作。
    private let startButton = GlassControlButton(
        symbol: "record.circle", diameter: 26, tooltip: "开始录制 (⌘⇧S)"
    )
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
    private var phase: RecordingControlPanel.Phase = .ready

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

        // 红点：录制中一直亮着，暂停 / 待开始时压暗——一眼能看出状态。
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(Theme.Colors.destructive).cgColor
        dot.layer?.cornerRadius = 4
        addSubview(dot)

        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor(name: nil) { $0.isDark ? .srgbInk(1, alpha: 1) : .srgbInk(0, alpha: 1) }
        label.alignment = .left
        addSubview(label)

        startButton.onClick = { [weak self] in self?.onStart?() }
        pauseButton.onClick = { [weak self] in self?.onTogglePause?() }
        stopButton.onClick = { [weak self] in self?.onStop?() }
        cancelButton.onClick = { [weak self] in self?.onCancel?() }
        for button in [startButton, pauseButton, stopButton, cancelButton] {
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
            width: 64, height: label.frame.height
        )
        let visible = visibleButtons
        for button in [startButton, pauseButton, stopButton, cancelButton] {
            button.isHidden = !visible.contains(button)
        }
        // 从右往左摆：最右边那颗永远是「退出去」（待开始是取消 / 录制中是取消）。
        var x = bounds.maxX - 12 - 26
        for button in visible {
            button.frame = NSRect(x: x, y: mid - 13, width: 26, height: 26)
            x -= 26 + 6
        }
    }

    /// 当前阶段真正露出来的按钮，**从右往左**列（layout 按这个顺序摆）。
    private var visibleButtons: [GlassControlButton] {
        switch phase {
        case .ready: [cancelButton, startButton]
        case .recording: [cancelButton, stopButton, pauseButton]
        }
    }

    /// 自检用：按钮在**自己坐标系**里的矩形。
    var startFrame: NSRect? { startButton.isHidden ? nil : startButton.frame }
    var pauseFrame: NSRect? { pauseButton.isHidden ? nil : pauseButton.frame }
    var stopFrame: NSRect? { stopButton.isHidden ? nil : stopButton.frame }
    var cancelFrame: NSRect? { cancelButton.isHidden ? nil : cancelButton.frame }

    func setElapsed(_ elapsed: TimeInterval) {
        guard phase == .recording else { return }
        let total = max(0, Int(elapsed.rounded(.down)))
        label.stringValue = String(format: "%02d:%02d", total / 60, total % 60)
    }

    func setPhase(_ phase: RecordingControlPanel.Phase) {
        guard self.phase != phase else { return }
        self.phase = phase
        label.stringValue = phase == .ready ? "准备录制" : "00:00"
        // 待开始态的红点压暗：框摆好了，但还没在录。
        dot.layer?.backgroundColor = NSColor(Theme.Colors.destructive)
            .withAlphaComponent(phase == .ready ? 0.35 : 1).cgColor
        needsLayout = true
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
