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

    /// 这次录制与麦克风的关系（控制条上那枚图标的三种状态）。
    enum MicrophoneState {
        /// 设置里没开（只录系统声音）。
        case off
        /// 会录 / 正在录。
        case active
        /// 开关开着却没启用（未授权 / 没有输入设备）——最需要注意的一态。
        case unavailable
    }

    var onStart: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 待开始态点了音频开关：交给外面改设置并回填状态（录制中点了不生效）。
    var onToggleSystemAudio: (() -> Void)?
    var onToggleMicrophone: (() -> Void)?

    private var panel: NSPanel?
    private var content: RecordingControlContentView?
    /// 面板定位的锚点（选区 + 屏幕）：切阶段改宽度时要重新贴回去。
    private var anchor: (selection: CGRect, screen: NSScreen?)?

    /// 给录制排除用：控制条不能出现在成片里。
    var windowNumber: Int? { panel.map { $0.windowNumber } }
    var isVisible: Bool { panel?.isVisible ?? false }
    /// 自检用：控制条在屏幕上的 frame（验「有没有压在选区上」）。
    var panelFrame: NSRect? { panel?.frame }

    /// 控制条高度。
    fileprivate static let height: CGFloat = 44
    /// 状态区固定宽度：红点（14 + 8）+ 计时 64 + 间隙 12 + 两个音频开关（24 + 6 + 24）= 154。
    fileprivate static let statusWidth: CGFloat = 154
    /// 状态区与按钮区之间的分组留白。
    fileprivate static let groupGap: CGFloat = 10
    /// 按钮直径与间距。
    fileprivate static let buttonDiameter: CGFloat = 26
    fileprivate static let buttonSpacing: CGFloat = 8
    /// 右侧边距。
    fileprivate static let trailingInset: CGFloat = 12
    /// 状态区里计时标签的固定宽度（monospacedDigit，够放「准备录制」四个字）。
    fileprivate static let labelWidth: CGFloat = 64

    /// 按阶段算宽度：待开始两颗按钮、录制中三颗，**不留多余空白**（按钮始终贴着状态区右侧）。
    fileprivate static func width(for phase: Phase) -> CGFloat {
        let buttons = phase == .ready ? 2 : 3
        let buttonArea = CGFloat(buttons) * buttonDiameter
            + CGFloat(buttons - 1) * buttonSpacing + trailingInset
        return statusWidth + groupGap + buttonArea
    }
    /// 音频开关（系统声音 / 麦克风）的直径：比主按钮小一档，视觉上属于「状态区」。
    fileprivate static let toggleDiameter: CGFloat = 24

    /// 贴着选区下方展示（下方放不下就挪到上方）。宽度按阶段算（见 `width(for:)`）。
    func present(near selectionRect: CGRect, in screen: NSScreen?, phase: Phase = .ready) {
        close()
        anchor = (selectionRect, screen)

        let size = CGSize(width: Self.width(for: phase), height: Self.height)
        let content = RecordingControlContentView(frame: NSRect(origin: .zero, size: size))
        content.onStart = { [weak self] in self?.onStart?() }
        content.onTogglePause = { [weak self] in self?.onTogglePause?() }
        content.onStop = { [weak self] in self?.onStop?() }
        content.onCancel = { [weak self] in self?.onCancel?() }
        content.onToggleSystemAudio = { [weak self] in self?.onToggleSystemAudio?() }
        content.onToggleMicrophone = { [weak self] in self?.onToggleMicrophone?() }
        content.setPhase(phase)
        self.content = content

        let panel = NSPanel(
            contentRect: NSRect(origin: origin(for: selectionRect, in: screen, size: size), size: size),
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

    /// 切阶段（待开始 → 录制中）：按钮多一颗，面板宽度跟着长，位置重新贴回选区。
    func setPhase(_ phase: Phase) {
        content?.setPhase(phase)
        resize(for: phase)
    }

    private func resize(for phase: Phase) {
        guard let panel, let anchor else { return }
        let size = CGSize(width: Self.width(for: phase), height: Self.height)
        panel.setFrame(
            NSRect(
                origin: origin(for: anchor.selection, in: anchor.screen, size: size),
                size: size
            ),
            display: true
        )
    }

    /// 麦克风状态：待开始态按设置显示，真开录后按引擎的实际结果更新。
    func setMicrophone(_ state: MicrophoneState) {
        content?.setMicrophone(state)
    }

    /// 系统声音开关状态（待开始态显示设置里的值）。
    func setSystemAudio(_ on: Bool) {
        content?.setSystemAudio(on)
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
    private func origin(for selectionRect: CGRect, in screen: NSScreen?, size: CGSize) -> CGPoint {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var y = selectionRect.minY - size.height - 8
        if y < visible.minY + 4 {
            y = selectionRect.maxY + 8
        }
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        let x = min(
            max(selectionRect.midX - size.width / 2, visible.minX + 4),
            visible.maxX - size.width - 4
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
    /// 待开始态点了音频开关：交给外面改设置并回填状态（录制中点了不生效）。
    var onToggleSystemAudio: (() -> Void)?
    var onToggleMicrophone: (() -> Void)?

    private let glass = NSVisualEffectView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "准备录制")
    /// 音频开关：**待开始态可以直接点**（CapCut 那类录屏的「录前先配好」），
    /// 录制中变成只读状态显示——省得为了开麦克风再跑去设置页。
    private let systemAudioButton = GlassControlButton(
        symbol: "speaker.wave.2.fill", diameter: 24, tooltip: "系统声音"
    )
    private let micButton = GlassControlButton(
        symbol: "mic.fill", diameter: 24, tooltip: "麦克风"
    )
    private var microphone: RecordingControlPanel.MicrophoneState = .off
    private var systemAudio = false
    /// 「开始」：待开始态的主操作（红色 = 录制的通用语言，和 CapCut 那类浮条一样）。
    private let startButton = GlassControlButton(
        symbol: "record.circle", diameter: 26, tooltip: "开始录制 (⌘⇧S)",
        iconTint: NSColor(Theme.Colors.destructive)
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

        systemAudioButton.onClick = { [weak self] in self?.onToggleSystemAudio?() }
        micButton.onClick = { [weak self] in self?.onToggleMicrophone?() }
        for button in [systemAudioButton, micButton] { addSubview(button) }
        applySystemAudio()
        applyMicrophone()

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
            width: RecordingControlPanel.labelWidth, height: label.frame.height
        )
        // 两个音频开关贴状态区右侧：**固定位置**（不随按钮数量变），免得录屏中图标挪位。
        let toggle = RecordingControlPanel.toggleDiameter
        var toggleX = label.frame.maxX + 12
        for button in [systemAudioButton, micButton] {
            button.frame = NSRect(x: toggleX, y: mid - toggle / 2, width: toggle, height: toggle)
            toggleX += toggle + 6
        }

        let visible = visibleButtons
        for button in [startButton, pauseButton, stopButton, cancelButton] {
            button.isHidden = !visible.contains(button)
        }
        // 从右往左摆：最右边那颗是**当前阶段的主操作**（待开始=开始，录制中=完成），
        // 与 CapCut 那类录屏浮条一致；左端依次是次要操作。
        let diameter = RecordingControlPanel.buttonDiameter
        let spacing = RecordingControlPanel.buttonSpacing
        var x = bounds.maxX - 12 - diameter
        for button in visible {
            button.frame = NSRect(x: x, y: mid - diameter / 2, width: diameter, height: diameter)
            x -= diameter + spacing
        }
    }

    /// 当前阶段真正露出来的按钮，**从右往左**列（layout 按这个顺序摆）。
    ///
    /// 右端永远是主操作：待开始是「开始」，录制中是「完成」——用户最想点的那颗不用找。
    private var visibleButtons: [GlassControlButton] {
        switch phase {
        case .ready: [startButton, cancelButton]
        case .recording: [stopButton, cancelButton, pauseButton]
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
        applyMicrophone()
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

    /// 麦克风状态（三态）：图标 + 悬停说明，录制前就能看出这次会不会录到旁白。
    func setMicrophone(_ state: RecordingControlPanel.MicrophoneState) {
        guard microphone != state else { return }
        microphone = state
        applyMicrophone()
    }

    /// 麦克风开关的三态外观。待开始态点它就是「开 / 关」，录制中只是状态显示。
    private func applyMicrophone() {
        switch microphone {
        case .off:
            micButton.symbolName = "mic.slash"
            micButton.iconTint = NSColor(Theme.Colors.textSecondary)
            micButton.toolTip = phase == .ready
                ? "麦克风：关（点一下打开，录制时录下你的讲解）"
                : "本次没录麦克风"
        case .active:
            micButton.symbolName = "mic.fill"
            micButton.iconTint = NSColor(Theme.Colors.success)
            micButton.toolTip = "麦克风：开（与系统声音混成一条音轨）"
        case .unavailable:
            micButton.symbolName = "mic.slash"
            micButton.iconTint = NSColor(Theme.Colors.warning)
            micButton.toolTip = "麦克风没启用：未授权或没有输入设备（本次只有系统声音）"
        }
    }

    /// 系统声音开关的外观（开=会录，关=不录）。
    func setSystemAudio(_ on: Bool) {
        guard systemAudio != on else { return }
        systemAudio = on
        applySystemAudio()
    }

    private func applySystemAudio() {
        systemAudioButton.symbolName = systemAudio ? "speaker.wave.2.fill" : "speaker.slash"
        systemAudioButton.iconTint =
            systemAudio ? NSColor(Theme.Colors.success) : NSColor(Theme.Colors.textSecondary)
        systemAudioButton.toolTip = systemAudio
            ? "系统声音：开（页面里的视频 / 音乐）"
            : "系统声音：关（点一下打开）"
    }
}
