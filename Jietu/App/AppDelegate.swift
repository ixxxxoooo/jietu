import AppKit
import AVFoundation
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    let logger = Logger(subsystem: "com.ixxxxoooo.jietu", category: "app")

    let settings = SettingsStore()
    let hotkeys = HotkeyCenter()
    let capture = CaptureEngine()
    let overlays = OverlayCoordinator()
    let quickAccess = QuickAccessPanelController()
    /// 这次原地编辑是从哪张浮窗卡片进来的：编辑确认后那张旧卡片让位（见 `deliver`）。
    var cardBeingEdited: UUID?
    let notifier = CaptureNotifier()
    var menuBar: MenuBarController?
    var onboarding: OnboardingWindowController?
    var settingsWindow: SettingsWindowController?

    /// 正在进行的滚动长图会话与控制条。
    var scrollingSession: ScrollingCaptureSession?
    var scrollingPanel: ScrollingCapturePanelController?
    var scrollingEscapeMonitor: Any?
    var isScrollingCancelled = false
    /// 正在进行的录屏会话与控制条 / 红框。
    var recordingEngine: RecordingEngine?
    var recordingHUD: RecordingControlPanel?
    var recordingBorder: RecordingBorderPanel?
    var recordingKeyMonitors: [Any] = []
    /// 已录时长（秒，暂停不计）：收工时的通知里要写。
    var recordingElapsed: TimeInterval = 0
    /// 录的是哪块屏：收工后的浮窗要落回同一块屏（和截图一个规矩）。
    var recordingDisplayID: CGDirectDisplayID?
    /// 最近截图自检的报告行（`popUp` 里的定时器闭包没法捕局部变量）。
    var recentMenuReport: [String] = []
    /// 正在被自检弹出的子菜单 / 这一张的名字（同上：不能让定时器闭包捕获 NSMenu）。
    var recentMenuUnderTest: NSMenu?
    var recentMenuShotName: String?
    /// 框选好了、**还没点「开始」**的那一档：红框 + 控制条先停着（`phase = .ready`）。
    var pendingRecording: (displayID: CGDirectDisplayID, region: CGRect)?

    /// 正在开着的那一个裁剪窗口（同时只允许一个）。
    var videoTrimController: VideoTrimController?
    /// GIF 导出的进度浮窗。
    var gifExportPanel: GifExportPanel?

    /// 滚动长图的右侧实时预览。
    var scrollingPreview: ScrollingPreviewPanel?
    /// 本次滚动长图的选区（含三套换算好的坐标）：用户中途改选区时跟着更新。
    var scrollingTarget: CaptureRegionTarget?
    /// 动作 → Carbon 热键引用 id。
    var hotkeyIDs: [HotkeyAction: UInt32] = [:]
    /// 动作 → 当前真正生效的组合键，注册失败时用它回滚。
    var activeHotkeys: [HotkeyAction: Hotkey] = [:]

    /// 启动时已有权限 = 当前进程可直接截图。
    ///
    /// 关键语义：`CGPreflightScreenCaptureAccess()` 会在用户刚授权后立刻返回 true，
    /// 但 ScreenCaptureKit 在**同一个进程**里仍然拿不到内容，必须重启。
    /// 所以这个值在启动时确定后就不再改，Onboarding 只负责提示重启。

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 必须在任何权限读取之前记下来：这是判断「要不要重启」的基准。
        ScreenCapturePermission.recordLaunchState()
        NSApp.setActivationPolicy(.accessory)
        // 外观跟着设置走：跟随系统（nil）或锁定浅色 / 深色。
        settings.appearance.apply()

        #if DEBUG
        // 自检模式：不建菜单栏、不注册热键，跑完自己退出。
        if CaptureSelfTest.handleCommandLineIfNeeded() {
            return
        }
        #endif

        // 单实例守卫：多开会让热键重复注册、浮窗／菜单栏各来一份。
        if handOffToExistingInstance() { return }

        // 跑单元测试时宿主是同一个 App bundle，不需要启动实际业务逻辑（菜单栏、全局热键、登录项、OCR 预热等）。
        guard !Self.isRunningTests else { return }

        setUpMenuBar()
        setUpHotkeys()
        setUpQuickAccess()
        setUpLaunchAtLogin()
        notifier.requestAuthorizationIfNeeded()
        OCRService.warmUp()

        #if DEBUG
        // 需要**完整接线**的自检：就地工具栏的「滚动截图」要真的把会话跑起来。
        // 它不归 `--selftest` 那批管（那批在这之前就 return 了，没有 AppDelegate 接线）。
        if CommandLine.arguments.contains(CaptureSelfTest.appLevelInlineScrollFlag) {
            runInlineScrollAppTest()
            return
        }
        if CommandLine.arguments.contains(CaptureSelfTest.appLevelRecentMenuFlag) {
            runRecentMenuAppTest()
            return
        }
        if CommandLine.arguments.contains(CaptureSelfTest.appLevelRecordingFlag) {
            runRecordingAppTest()
            return
        }
        if CommandLine.arguments.contains(CaptureSelfTest.appLevelTrimFlag) {
            runTrimAppTest()
            return
        }
        #endif

        if !ScreenCapturePermission.isGranted {
            logger.notice("screen recording permission missing, showing onboarding")
            // 启动时不主动向系统弹窗申请授权，交由用户在引导页中点击「授权屏幕录制」时手动触发
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
    }

    // MARK: - Wiring

    func setUpMenuBar() {
        let menuBar = MenuBarController()
        menuBar.onCaptureArea = { [weak self] in self?.handleAreaCapture() }
        menuBar.onCaptureWindow = { [weak self] in self?.handleWindowCapture() }
        menuBar.onCaptureFullScreen = { [weak self] in self?.handleFullScreenCapture() }
        menuBar.onCaptureTimed = { [weak self] seconds in self?.handleTimedCapture(after: seconds) }
        menuBar.onCaptureScrolling = { [weak self] in self?.handleScrollingCapture() }
        menuBar.hotkeyProvider = { [weak self] action in self?.settings.hotkey(for: action) }
        menuBar.onRecordRegion = { [weak self] in self?.handleScreenRecording(mode: .region) }
        menuBar.onRecordWindow = { [weak self] in self?.handleScreenRecording(mode: .window) }
        menuBar.onRecordFullScreen = { [weak self] in self?.handleScreenRecording(mode: .fullScreen) }
        menuBar.onOpenRecent = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        menuBar.onSelectHistoryItem = { [weak self] item in
            self?.openHistoryItem(item)
        }
        menuBar.onClearRecents = { [weak self] in self?.clearAllHistory() }
        menuBar.onOpenFolder = { [weak self] in self?.openSaveFolder() }

        menuBar.onAuthorizeScreenRecording = { PermissionDragController.shared.present(pane: .screenRecording) }
        menuBar.onAuthorizeAccessibility = { PermissionDragController.shared.present(pane: .accessibility) }
        menuBar.onOpenOnboarding = { [weak self] in self?.showOnboarding() }
        menuBar.onOpenSettings = { [weak self] in self?.showSettings() }
        menuBar.onRelaunch = { ScreenCapturePermission.relaunchApp() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.historyItemsProvider = { [weak self] in self?.historyItems() ?? [] }
        menuBar.recentProvider = { [weak self] in self?.settings.recentCaptureURLs ?? [] }
        menuBar.refresh()
        self.menuBar = menuBar
    }

    func setUpHotkeys() {
        // 默认全部不设：只有用户自己配过的动作才注册。
        for action in HotkeyAction.allCases {
            guard let hotkey = settings.hotkey(for: action) else { continue }
            applyHotkey(hotkey, for: action)
        }
    }

    /// 某个热键被触发时执行对应动作。
    func perform(_ action: HotkeyAction) {
        switch action {
        case .areaCapture:
            handleAreaCapture()
        case .windowCapture:
            handleWindowCapture()
        case .fullScreenCapture:
            handleFullScreenCapture()
        case .timedCapture:
            handleTimedCapture(after: HotkeyAction.timedCaptureDelay)
        case .scrollingCapture:
            handleScrollingCapture()
        case .screenRecording:
            handleScreenRecording(mode: .region)
        case .windowRecording:
            handleScreenRecording(mode: .window)
        case .fullScreenRecording:
            handleScreenRecording(mode: .fullScreen)
        }
    }

    /// 只注册、不注销，成功后记录生效组合键。
    @discardableResult
    func register(_ hotkey: Hotkey, for action: HotkeyAction) -> Bool {
        let id = hotkeys.register(hotkey) { [weak self] in
            self?.perform(action)
        }
        guard let id else { return false }
        hotkeyIDs[action] = id
        activeHotkeys[action] = hotkey
        return true
    }

    func unregisterHotkey(for action: HotkeyAction) {
        if let id = hotkeyIDs.removeValue(forKey: action) {
            hotkeys.unregister(id)
        }
        activeHotkeys.removeValue(forKey: action)
    }

    /// 注销某个动作的旧热键并注册新热键；`hotkey` 为 nil 表示清除该动作的快捷键。
    ///
    /// Carbon 热键不能原地修改，设置页改了组合键只能走这条路径重注册。
    /// 注册失败（被别的 App 占用，或与另一个动作撞车）时回滚到上一个可用组合键并返回 false。
    @discardableResult
    func applyHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) -> Bool {
        let previous = activeHotkeys[action]
        unregisterHotkey(for: action)

        guard let hotkey else {
            logger.notice("cleared \(action.rawValue, privacy: .public) hotkey")
            return true
        }

        // 同一组合键不能绑两个动作，Carbon 那边只会静默失败，这里先给出可读原因。
        if let clash = activeHotkeys.first(where: { $0.key != action && $0.value == hotkey })?.key {
            logger.error(
                "hotkey \(hotkey.displayString, privacy: .public) already bound to \(clash.rawValue, privacy: .public)"
            )
            if let previous { register(previous, for: action) }
            return false
        }

        if register(hotkey, for: action) {
            logger.notice(
                "registered \(action.rawValue, privacy: .public) hotkey \(hotkey.displayString, privacy: .public)"
            )
            return true
        }

        logger.error(
            "failed to register \(action.rawValue, privacy: .public) hotkey \(hotkey.displayString, privacy: .public)"
        )
        // 回滚：把上一个可用的组合键重新注册回来，避免用户彻底失去快捷键。
        if let previous { register(previous, for: action) }
        return false
    }

    func setUpQuickAccess() {
        quickAccess.autoCloseDelay = settings.quickAccessAutoCloseDelay
        quickAccess.position = settings.quickAccessPosition
        quickAccess.onCopy = { image in
            CaptureOutput.copyToPasteboard(image)
        }
        quickAccess.onSave = { [weak self] image in
            self?.saveAs(image)
        }
        quickAccess.onAnnotate = { [weak self] image, cardID in
            self?.openInlineEditor(image, allowsCrop: true, sourceCard: cardID)
        }
        quickAccess.onPin = { image in
            PinWindowController.pin(image: image, on: NSScreen.main)
        }
        // 录屏收工的那张卡：文件已经落盘了，能做的就是「拿去看 / 拿去找 / 拿去用」。
        quickAccess.onPlayVideo = { url in
            VideoQuickLookPresenter.shared.present(url)
        }
        quickAccess.onRevealVideo = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        quickAccess.onCopyVideoFile = { url in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
        }
        quickAccess.onSaveVideo = { [weak self] url in
            self?.saveVideoAs(url)
        }
        quickAccess.onTrimVideo = { [weak self] url in
            self?.openVideoTrim(url)
        }
        quickAccess.onExportGif = { [weak self] url in
            self?.exportVideoAsGif(url)
        }
        overlays.onFinish = { [weak self] outcome in
            guard let self else { return }
            // 遮罩只服务一次：**无论结果如何**都把用途复位。
            // 否则「滚动长图那次取消选区」会把 .regionPick 留在原地，
            // 下一次普通区域截图就会误走滚动长图（弹出「自动截图」面板）。
            self.overlays.purpose = .screenshot
            self.handleOverlayOutcome(outcome)
        }
        overlays.onSaveImage = { [weak self] image in
            guard let self else { return }
            // 遮罩窗在最上层，保存面板会被挡住：先隐藏。
            self.overlays.setOverlayHidden(true)
            let saved = self.saveAs(image, ensuresHistory: true)
            if saved {
                // 保存完毕等同于确认，播放提示音、写入剪贴板，收起遮罩不再回到之前的区域截图状态。
                if self.settings.playShutterSound {
                    CaptureOutput.playShutterSound()
                }
                self.copyToClipboard(image)
                self.overlays.finishFromSave()
            } else {
                // 用户在保存面板中点了取消：恢复遮罩继续编辑。
                self.overlays.setOverlayHidden(false)
            }
        }
        overlays.onPinImage = { image, screenRect in
            PinWindowController.pin(image: image, on: NSScreen.main, targetFrame: screenRect)
        }
        overlays.annotationDefaults = settings.annotationDefaults
        overlays.onAnnotationDefaultsChange = { [weak self] updated in
            self?.settings.annotationDefaults = updated
        }
        overlays.editorShortcutsProvider = { [weak self] in
            self?.settings.editorShortcuts ?? .standard
        }
        // 滚动长图起步：选区不急着交付 —— 鼠标一停住（或一松手）就把
        // 「手动 / 自动」浮到选框下方；在那之前用户还能继续调选区。
        overlays.onSelectionPaused = { [weak self] snapshot, localRect in
            self?.presentScrollingModeBar(snapshot: snapshot, localRect: localRect)
        }
        overlays.onSelectionChanged = { [weak self] snapshot, localRect in
            self?.updateScrollingSelection(snapshot: snapshot, localRect: localRect)
        }
        // 就地编辑工具栏里的「滚动截图 → 手动 / 自动」：用户已经选过模式了，
        // 直接拿当前选区开跑，不再弹「手动 / 自动」模式条。
        // 钉图上的「编辑」：把钉图收掉，恢复到原地编辑模式（居中预览并展示原地工具栏）。
        PinWindowController.onRequestEdit = { [weak self] image, frame in
            self?.openInlineEditor(image, anchor: frame, allowsCrop: true)
        }
        // 录屏：框好区域（或点一下窗口）就把遮罩收掉、开录。
        overlays.onRecordRegionPicked = { [weak self] snapshot, localRect in
            self?.beginRecording(snapshot: snapshot, localRect: localRect)
        }
        overlays.onScrollCapture = { [weak self] snapshot, mode, localRect in
            self?.startScrollingCaptureFromInline(
                snapshot: snapshot, mode: mode, localRect: localRect
            )
        }
    }

    /// 已经有同 bundle id 的实例在跑？把前台交给它，然后自己退出。
    ///
    /// 走 LaunchServices 正常启动本来就只会有一个实例；这条守卫是兜底：
    /// 直接运行二进制、或用 `open -n` 之类的强制多开时，由这里收敛回一个。
    ///
    /// - Returns: `true` 表示已交接给既有实例，本进程应当立即停下。
    func handOffToExistingInstance() -> Bool {
        // 跑单元测试时宿主就是同一个 App bundle，而 App 通常正开着；
        // 这里必须放行，否则测试根本起不来。
        guard !Self.isRunningTests else { return false }
        #if DEBUG
        // app 级自检常与正式实例同时在场（它要真接线，不能当成"多开"被杀掉）。
        for flag in [
            CaptureSelfTest.appLevelInlineScrollFlag, CaptureSelfTest.appLevelRecordingFlag,
            CaptureSelfTest.appLevelRecentMenuFlag, CaptureSelfTest.videoToolsFlag,
            CaptureSelfTest.appLevelTrimFlag,
        ] where CommandLine.arguments.contains(flag) {
            return false
        }
        #endif
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return false }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != selfPID && !$0.isTerminated }
        guard let existing = others.first else { return false }

        logger.notice("another instance is already running, handing off")
        existing.activate()
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    /// 当前进程是不是 XCTest 宿主。
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }


    // MARK: - Support

    func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(settings: settings)
        }
        onboarding?.present()
    }

    func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(settings: settings)
            controller.onHotkeyChange = { [weak self] action, hotkey in
                guard let self else { return }
                guard self.applyHotkey(hotkey, for: action) else {
                    // 回滚设置里的组合键，并提示占用。
                    if self.settings.hotkey(for: action) != self.activeHotkeys[action] {
                        self.settings.setHotkey(self.activeHotkeys[action], for: action)
                    }
                    if let hotkey {
                        self.presentHotkeyFailure(hotkey, action: action)
                    }
                    return
                }
            }
            settingsWindow = controller
        }
        settingsWindow?.present()
    }

    /// 热键被占用时的提示。
    func presentHotkeyFailure(_ hotkey: Hotkey, action: HotkeyAction) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(action.title)」的快捷键 \(hotkey.displayString) 注册失败"
        alert.informativeText = "该组合键可能已被系统、其它 App 或本 App 的其它动作占用，已恢复为原来的快捷键。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func presentCaptureFailure(_ error: Error) {
        logger.error("capture failed: \(String(describing: error))")

        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = (error as? CaptureError)?.errorDescription ?? "截图失败"
        alert.informativeText = (error as? CaptureError)?.recoverySuggestion
            ?? error.localizedDescription
        // 屏幕录制的授权在授权时的那个进程里不生效，所以这类失败给「重启」这条捷径。
        let suggestion = (error as? CaptureError)?.suggestsRelaunch ?? false
        alert.addButton(withTitle: suggestion ? "重启 Jietu" : "打开系统设置")
        alert.addButton(withTitle: "好")

        if alert.runModal() == .alertFirstButtonReturn {
            if suggestion {
                ScreenCapturePermission.relaunchApp()
            } else {
                ScreenCapturePermission.openSystemSettings()
            }
        }
    }
}
