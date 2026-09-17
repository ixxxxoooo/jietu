import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.ixxxxoooo.jietu", category: "app")

    private let settings = SettingsStore()
    private let hotkeys = HotkeyCenter()
    private let capture = CaptureEngine()
    private let overlays = OverlayCoordinator()
    private let quickAccess = QuickAccessPanelController()
    private let notifier = CaptureNotifier()
    private var menuBar: MenuBarController?
    private var onboarding: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?
    private var historyPanel: HistoryPanelController?
    /// 正在进行的滚动长图会话与控制条。
    private var scrollingSession: ScrollingCaptureSession?
    private var scrollingPanel: ScrollingCapturePanelController?
    private var scrollingEscapeMonitor: Any?
    private var isScrollingCancelled = false
    /// 滚动长图的右侧实时预览。
    private var scrollingPreview: ScrollingPreviewPanel?
    /// 本次滚动长图的选区（含三套换算好的坐标）：用户中途改选区时跟着更新。
    private var scrollingTarget: ScrollingTarget?
    /// 会话内的截图历史（新截的即时可见，不必先保存）。
    private var sessionHistory: [HistoryItem] = []
    private var annotationEditors: [AnnotationEditorWindowController] = []
    /// 动作 → Carbon 热键引用 id。
    private var hotkeyIDs: [HotkeyAction: UInt32] = [:]
    /// 动作 → 当前真正生效的组合键，注册失败时用它回滚。
    private var activeHotkeys: [HotkeyAction: Hotkey] = [:]

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

        setUpMenuBar()
        setUpHotkeys()
        setUpQuickAccess()
        setUpLaunchAtLogin()
        notifier.requestAuthorizationIfNeeded()

        if !ScreenCapturePermission.isGranted {
            logger.notice("screen recording permission missing, showing onboarding")
            // 关键：必须主动调用一次申请 API，macOS 才会把本 App 注册进
            // 「系统设置 › 隐私与安全性 › 屏幕录制」列表；否则用户根本找不到可勾选项。
            _ = ScreenCapturePermission.request()
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
    }

    // MARK: - Wiring

    private func setUpMenuBar() {
        let menuBar = MenuBarController()
        menuBar.onCaptureArea = { [weak self] in self?.handleAreaCapture() }
        menuBar.onCaptureWindow = { [weak self] in self?.handleWindowCapture() }
        menuBar.onCaptureFullScreen = { [weak self] in self?.handleFullScreenCapture() }
        menuBar.onCaptureTimed = { [weak self] seconds in self?.handleTimedCapture(after: seconds) }
        menuBar.onCaptureScrolling = { [weak self] in self?.handleScrollingCapture() }
        menuBar.onOpenRecent = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        menuBar.onClearRecents = { [weak self] in self?.settings.clearRecentCaptures() }
        menuBar.onOpenFolder = { [weak self] in self?.openSaveFolder() }
        menuBar.onOpenHistory = { [weak self] in self?.showHistory() }
        menuBar.onAuthorizeScreenRecording = { PermissionDragController.shared.present() }
        menuBar.onOpenOnboarding = { [weak self] in self?.showOnboarding() }
        menuBar.onOpenSettings = { [weak self] in self?.showSettings() }
        menuBar.onRelaunch = { ScreenCapturePermission.relaunchApp() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.recentProvider = { [weak self] in self?.settings.recentCaptureURLs ?? [] }
        menuBar.refresh()
        self.menuBar = menuBar
    }

    private func setUpHotkeys() {
        // 默认全部不设：只有用户自己配过的动作才注册。
        for action in HotkeyAction.allCases {
            guard let hotkey = settings.hotkey(for: action) else { continue }
            applyHotkey(hotkey, for: action)
        }
    }

    /// 某个热键被触发时执行对应动作。
    private func perform(_ action: HotkeyAction) {
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
        }
    }

    /// 只注册、不注销，成功后记录生效组合键。
    @discardableResult
    private func register(_ hotkey: Hotkey, for action: HotkeyAction) -> Bool {
        let id = hotkeys.register(hotkey) { [weak self] in
            self?.perform(action)
        }
        guard let id else { return false }
        hotkeyIDs[action] = id
        activeHotkeys[action] = hotkey
        return true
    }

    private func unregisterHotkey(for action: HotkeyAction) {
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
    private func applyHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) -> Bool {
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

    private func setUpQuickAccess() {
        quickAccess.autoCloseDelay = settings.quickAccessAutoCloseDelay
        quickAccess.position = settings.quickAccessPosition
        quickAccess.onCopy = { image in
            CaptureOutput.copyToPasteboard(image)
        }
        quickAccess.onSave = { [weak self] image in
            self?.saveAs(image)
        }
        quickAccess.onAnnotate = { [weak self] image in
            self?.openAnnotationEditor(image)
        }
        quickAccess.onPin = { image in
            PinWindowController.pin(image: image, on: NSScreen.main)
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
            // 遮罩窗在最上层，保存面板会被挡住：先隐藏，存完再恢复。
            self.overlays.setOverlayHidden(true)
            self.saveAs(image)
            self.overlays.setOverlayHidden(false)
        }
        overlays.onPinImage = { image, screenRect in
            PinWindowController.pin(image: image, on: NSScreen.main, targetFrame: screenRect)
        }
        overlays.annotationDefaults = settings.annotationDefaults
        overlays.onAnnotationDefaultsChange = { [weak self] updated in
            self?.settings.annotationDefaults = updated
        }
        // 滚动长图起步：选区不急着交付 —— 鼠标一停住（或一松手）就把
        // 「手动 / 自动」浮到选框下方；在那之前用户还能继续调选区。
        overlays.onSelectionPaused = { [weak self] snapshot, localRect in
            self?.presentScrollingModeBar(snapshot: snapshot, localRect: localRect)
        }
        overlays.onSelectionChanged = { [weak self] snapshot, localRect in
            self?.updateScrollingSelection(snapshot: snapshot, localRect: localRect)
        }
    }

    /// 已经有同 bundle id 的实例在跑？把前台交给它，然后自己退出。
    ///
    /// 走 LaunchServices 正常启动本来就只会有一个实例；这条守卫是兜底：
    /// 直接运行二进制、或用 `open -n` 之类的强制多开时，由这里收敛回一个。
    ///
    /// - Returns: `true` 表示已交接给既有实例，本进程应当立即停下。
    private func handOffToExistingInstance() -> Bool {
        // 跑单元测试时宿主就是同一个 App bundle，而 App 通常正开着；
        // 这里必须放行，否则测试根本起不来。
        guard !Self.isRunningTests else { return false }
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
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    // MARK: - Capture flow

    /// 需要「屏幕录制」权限的入口统一走这里。
    ///
    /// 每次都**现读**，不缓存启动时的快照——用户刚在系统设置里勾完就回来时，
    /// 缓存的旧值会让入口一直说「没权限」。不可用就打开权限引导：
    /// 引导页里既能看到实时状态，也有「重新检测」和「重启 Jietu」两个出口。
    private func requireScreenCapturePermission() -> Bool {
        guard !ScreenCapturePermission.isGranted else { return true }
        logger.notice("capture requested without screen recording permission")
        showOnboarding()
        return false
    }

    private func handleAreaCapture() {
        overlays.purpose = .screenshot
        guard !overlays.isPresenting else { return }

        guard requireScreenCapturePermission() else { return }

        Task { @MainActor in
            do {
                let snapshots = try await capture.captureAllDisplays()
                // 必须在遮罩窗出现之前枚举窗口，否则会把遮罩自己也算进去。
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                logger.notice(
                    "captured \(snapshots.count) display(s), \(windows.count) window(s) on screen"
                )
                overlays.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: settings.editorMode == .inline
                )
            } catch {
                presentCaptureFailure(error)
            }
        }
    }

    /// 全屏截图：直接抓鼠标所在显示器，不弹遮罩。
    private func handleFullScreenCapture() {
        guard !overlays.isPresenting else { return }
        guard requireScreenCapturePermission() else { return }

        Task { @MainActor in
            do {
                let snapshots = try await capture.captureAllDisplays()
                guard let snapshot = snapshotUnderMouse(snapshots) ?? snapshots.first else {
                    throw CaptureError.noDisplays
                }
                deliver(snapshot.image, onDisplay: snapshot.displayID)
            } catch {
                presentCaptureFailure(error)
            }
        }
    }

    /// 窗口截图：抓鼠标当前悬停的那个窗口，不弹遮罩。
    private func handleWindowCapture() {
        guard !overlays.isPresenting else { return }
        guard requireScreenCapturePermission() else { return }

        let mouse = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: mouse.x, y: DisplayGeometry.referenceHeight - mouse.y)
        let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
        guard let window = WindowHitTester.frontmost(atCGPoint: cgPoint, in: windows) else {
            presentCaptureFailure(CaptureError.noWindowUnderCursor)
            return
        }

        Task { @MainActor in
            do {
                let image = try await capture.captureWindow(window)
                deliver(image, onDisplay: displayID(containing: window))
            } catch {
                presentCaptureFailure(error)
            }
        }
    }

    /// 定时截图：延时后走区域截图流程。
    private func handleTimedCapture(after seconds: TimeInterval) {
        guard !overlays.isPresenting else { return }
        logger.notice("timed capture scheduled in \(seconds)s")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            handleAreaCapture()
        }
    }

    // MARK: - Scrolling capture

    /// 滚动长图：先用遮罩取一块选区；鼠标一停住就把「手动 / 自动」浮到选框下方，
    /// 用户点哪一个才开跑。
    private func handleScrollingCapture() {
        // 上一次可能停在那条模式条上（用户没点开始也没取消）：先收干净，
        // 否则新面板会把它盖住、旧的那条一直留在屏幕上。
        if scrollingPanel != nil, scrollingSession == nil {
            logger.notice("dismissing leftover scrolling panel")
            dismissScrollingPanel()
        }
        guard !overlays.isPresenting else {
            logger.notice("scrolling capture ignored: overlay is presenting")
            return
        }
        guard scrollingSession == nil else {
            logger.notice("scrolling capture ignored: a session is running")
            return
        }
        guard requireScreenCapturePermission() else { return }

        Task { @MainActor in
            do {
                let snapshots = try await capture.captureAllDisplays()
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                overlays.purpose = .regionPick
                overlays.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: false
                )
            } catch {
                overlays.purpose = .screenshot
                presentCaptureFailure(error)
            }
        }
    }

    /// 自动滚动要「辅助功能」权限：没有就先申请，并让用户选「改用手动」或「去系统设置」。
    private func resolveScrollingMode(
        _ requested: ScrollingCaptureSession.Mode
    ) -> ScrollingCaptureSession.Mode {
        guard requested == .automatic, !AccessibilityPermission.isGranted else { return requested }
        AccessibilityPermission.request()

        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "自动滚动需要「辅助功能」权限"
        alert.informativeText =
            "系统已弹出授权申请；授权后重试即可自动滚动。\n"
            + "也可以现在就改用手动滚动：把鼠标放进选区，自己往下滚。"
        alert.addButton(withTitle: "改用手动滚动")
        alert.addButton(withTitle: "打开系统设置")
        if alert.runModal() == .alertSecondButtonReturn {
            AccessibilityPermission.openSystemSettings()
        }
        logger.notice("auto scroll unavailable, falling back to manual")
        return .manual
    }

    // MARK: - Scrolling capture: selection

    /// 滚动长图选区：三套坐标一次算好，用户中途改选区时跟着更新。
    private struct ScrollingTarget {
        let snapshot: DisplaySnapshot
        /// SCK 的 `sourceRect`（本显示器内、原点左上）。
        let region: CGRect
        /// 全局 cg 坐标（自动滚动的合成滚轮事件发到这里）。
        let globalRect: CGRect
        /// 选区在 AppKit 全局坐标里的矩形（控制条与预览都贴它定位）。
        let selectionRect: CGRect
    }

    private func makeScrollingTarget(
        snapshot: DisplaySnapshot,
        localRect: CGRect
    ) -> ScrollingTarget? {
        let screenFrame = snapshot.screenFrameInPoints
        // local（原点左下）→ 显示器坐标（原点左上），SCK 的 sourceRect 用后者。
        let region = CGRect(
            x: localRect.minX,
            y: screenFrame.height - localRect.maxY,
            width: localRect.width,
            height: localRect.height
        )
        guard region.width >= 8, region.height >= 8 else { return nil }

        // 自动滚动要往「全局 cg 坐标」发事件（原点主屏左上），这里换算一次。
        let screen = NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID }
        let globalRect = CGRect(
            origin: screen.map {
                DisplayGeometry.cgPoint(fromLocal: localRect.origin, screen: $0)
            } ?? localRect.origin,
            size: localRect.size
        )

        let selectionRect = CGRect(
            x: screenFrame.minX + localRect.minX,
            y: screenFrame.minY + localRect.minY,
            width: localRect.width,
            height: localRect.height
        )
        return ScrollingTarget(
            snapshot: snapshot,
            region: region,
            globalRect: globalRect,
            selectionRect: selectionRect
        )
    }

    /// 鼠标在选区上停住（或松手）：把紧凑的「手动 / 自动」条浮到选框下方。
    private func presentScrollingModeBar(snapshot: DisplaySnapshot, localRect: CGRect) {
        guard overlays.purpose == .regionPick, scrollingSession == nil else { return }
        guard let target = makeScrollingTarget(snapshot: snapshot, localRect: localRect) else {
            return
        }
        scrollingTarget = target

        // 已经浮着就只挪位置（用户还在调选区）。
        if let panel = scrollingPanel {
            panel.move(near: target.selectionRect)
            return
        }

        let panel = ScrollingCapturePanelController()
        scrollingPanel = panel
        isScrollingCancelled = false

        panel.onStartManual = { [weak self] in self?.beginScrollingSession(mode: .manual) }
        panel.onStartAuto = { [weak self] in self?.beginScrollingSession(mode: .automatic) }
        panel.onFinish = { [weak self] in self?.scrollingSession?.stop() }
        panel.onCancel = { [weak self] in self?.cancelScrollingCapture() }

        panel.present(near: target.selectionRect)
        registerScrollingEscapeMonitor()
    }

    /// 选区被拖动 / 缩放 / 清空：模式条一路贴着选框走；选区没了就把它收掉。
    private func updateScrollingSelection(snapshot: DisplaySnapshot, localRect: CGRect?) {
        guard overlays.purpose == .regionPick, scrollingSession == nil else { return }
        guard let localRect,
            let target = makeScrollingTarget(snapshot: snapshot, localRect: localRect)
        else {
            dismissScrollingPanel()
            return
        }
        scrollingTarget = target
        scrollingPanel?.move(near: target.selectionRect)
    }

    /// 只收控制条（不动遮罩）：用户改了选区 / 重开一次滚动长图时用。
    private func dismissScrollingPanel() {
        removeScrollingEscapeMonitor()
        scrollingPanel?.close()
        scrollingPanel = nil
        scrollingTarget = nil
    }

    // MARK: - Scrolling capture: session

    /// 用户点了「手动 / 自动」：这时候才把遮罩切成取景框，然后开跑。
    private func beginScrollingSession(mode: ScrollingCaptureSession.Mode) {
        guard scrollingSession == nil, let panel = scrollingPanel,
            let target = scrollingTarget
        else { return }

        // 自动滚动要合成滚轮事件，没授权就先申请并给用户选择。
        let effective = mode == .automatic ? resolveScrollingMode(.automatic) : .manual

        // 遮罩切成取景框（鼠标穿透、前台还给用户）：页面要能滚起来。
        overlays.beginScrollCaptureChrome()

        let session = ScrollingCaptureSession(
            engine: capture,
            target: ScrollingCaptureSession.Target(
                displayID: target.snapshot.displayID,
                regionInPoints: target.region,
                regionInGlobalCGPoints: target.globalRect
            )
        )
        session.mode = effective
        // 自动滚动没有「人手停顿」，4 拍（1 秒）就够判定到底；手动保留 6 拍（1.5 秒）。
        session.idleIntervalsToStop = effective == .automatic ? 4 : 6
        // 起步宽限：手动模式多给点时间让用户把鼠标挪进选区（自动 2 秒足够它自己动）。
        session.startupIntervalsToStop = effective == .automatic ? 8 : 20
        session.onProgress = { [weak panel] height in
            panel?.update(height: height)
        }

        // 右侧实时预览：贴在选区右边（放不下会自己翻到左边）。
        let preview = ScrollingPreviewPanel()
        preview.present(near: target.selectionRect)
        session.onPreview = { [weak preview] image in
            preview?.update(image: image)
        }
        scrollingPreview = preview

        scrollingSession = session
        panel.setRunning(mode: effective)

        Task { @MainActor in
            let image = await session.run()
            finishScrollingCapture(image: image, displayID: target.snapshot.displayID)
        }
    }

    /// 还没开跑就「取消」：把控制条与遮罩一起收掉。
    private func cancelScrollingCapture() {
        isScrollingCancelled = true
        if let session = scrollingSession {
            session.stop()
        } else {
            finishScrollingCapture(image: nil, displayID: CGMainDisplayID())
        }
    }

    /// Esc 结束采样（控制条未必拿得到焦点，这里再兜一层）。
    private func registerScrollingEscapeMonitor() {
        removeScrollingEscapeMonitor()
        scrollingEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.scrollingPanel != nil else { return event }
            // 运行中就停会话；还停在模式条上就连遮罩一起收掉。
            if self.scrollingSession != nil {
                self.scrollingSession?.stop()
            } else {
                self.cancelScrollingCapture()
            }
            return nil
        }
    }

    private func removeScrollingEscapeMonitor() {
        if let scrollingEscapeMonitor {
            NSEvent.removeMonitor(scrollingEscapeMonitor)
        }
        scrollingEscapeMonitor = nil
    }

    private func finishScrollingCapture(image: CGImage?, displayID: CGDirectDisplayID) {
        removeScrollingEscapeMonitor()
        scrollingPanel?.close()
        scrollingPanel = nil
        scrollingSession = nil
        scrollingPreview?.close()
        scrollingPreview = nil
        scrollingTarget = nil
        // 遮罩在滚动期间留着当取景框；停在模式条上时也还开着 —— 两条路都关掉。
        overlays.releaseScrollChrome()
        overlays.cancel()

        let cancelled = isScrollingCancelled
        isScrollingCancelled = false
        guard !cancelled else { return }

        guard let image else {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "没有捕获到滚动内容"
            alert.informativeText =
                "选区里得是「整块能滚动的页面」，而且要真的滚起来：\n"
                + "· 手动：点完「手动」把鼠标放进选区，自己往下滚；\n"
                + "· 自动：Jietu 会自己发滚轮，但鼠标停在图表 / 下拉菜单这类会吃掉滚轮的控件上时会带不动。\n"
                + "换个区域或改用手动再试一次。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        deliver(image, onDisplay: displayID)
    }

    private func snapshotUnderMouse(_ snapshots: [DisplaySnapshot]) -> DisplaySnapshot? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
            let id = screen.jietu_displayID
        else { return nil }
        return snapshots.first { $0.displayID == id }
    }

    private func displayID(containing window: WindowInfo) -> CGDirectDisplayID {
        let center = CGPoint(
            x: window.frameInCGPoints.midX,
            y: DisplayGeometry.referenceHeight - window.frameInCGPoints.midY
        )
        return NSScreen.screens.first { $0.frame.contains(center) }?.jietu_displayID
            ?? NSScreen.main?.jietu_displayID
            ?? 0
    }

    private func handleOverlayOutcome(_ outcome: OverlayCoordinator.Outcome) {
        switch outcome {
        case .cancelled:
            // 遮罩被取消（Esc / 右键）：滚动长图还停在「选模式」这一步时，
            // 挂在选框下面的那条模式条也得一起收掉。
            if scrollingSession == nil { dismissScrollingPanel() }
        case .captured(let image, let displayID, let screenRect, let annotated):
            if annotated {
                // 已在遮罩里原地标注完成，直接走交付流程。
                deliver(image, onDisplay: displayID)
            } else {
                handleCaptured(image, onDisplay: displayID, screenRect: screenRect)
            }
        }
    }

    /// 截图完成后的分流：原地编辑 / 浮窗预览。
    private func handleCaptured(
        _ image: CGImage,
        onDisplay displayID: CGDirectDisplayID,
        screenRect: CGRect
    ) {
        switch settings.editorMode {
        case .inline:
            if settings.playShutterSound {
                CaptureOutput.playShutterSound()
            }
            // 截完立刻进剪贴板：原地编辑期间（甚至取消编辑）也能直接去别处粘贴。
            // 编辑器中点 ✓ 会再写一次，把带标注的成图覆盖上去。
            copyToClipboard(image)
            openAnnotationEditor(image, anchor: screenRect)
        case .window:
            deliver(image, onDisplay: displayID)
        }
    }

    /// 按设置把成图写进剪贴板（关掉就不再写）。
    private func copyToClipboard(_ image: CGImage) {
        guard settings.copyToClipboard else { return }
        if !CaptureOutput.copyToPasteboard(image) {
            logger.error("clipboard write failed")
        }
    }

    private func deliver(_ image: CGImage, onDisplay displayID: CGDirectDisplayID) {
        logger.notice("delivering \(image.width)x\(image.height) capture")
        recordHistory(image)
        menuBar?.flashCaptureFeedback()

        if settings.playShutterSound {
            CaptureOutput.playShutterSound()
        }
        copyToClipboard(image)
        if settings.saveToDisk {
            save(image)
        }

        quickAccess.autoCloseDelay = settings.quickAccessAutoCloseDelay
        quickAccess.position = settings.quickAccessPosition
        quickAccess.present(
            image: image,
            onDisplay: displayID,
            saveDirectory: settings.saveDirectory
        )
    }

    /// 打开标注编辑器。
    ///
    /// - Parameter anchor: 选区在屏幕上的矩形（原地编辑时把窗口放到选区附近）。
    private func openAnnotationEditor(_ image: CGImage, anchor: CGRect? = nil) {
        let controller = AnnotationEditorWindowController(
            image: image,
            anchor: anchor,
            annotationDefaults: settings.annotationDefaults
        )
        controller.onCopy = { rendered in
            CaptureOutput.copyToPasteboard(rendered)
        }
        controller.onSave = { [weak self] rendered in
            self?.saveAs(rendered)
        }
        controller.onAnnotationDefaultsChange = { [weak self] updated in
            self?.settings.annotationDefaults = updated
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            self.annotationEditors.removeAll { $0 === controller }
        }
        annotationEditors.append(controller)
        controller.present()
    }

    private func save(_ image: CGImage) {
        do {
            let url = try CaptureOutput.save(
                image,
                toDirectory: settings.saveDirectory,
                format: settings.saveFormat,
                quality: settings.jpegQuality,
                nameTemplate: settings.effectiveFilenameTemplate
            )
            didSave(to: url)
        } catch {
            logger.error("save failed: \(error.localizedDescription)")
        }
    }

    /// 「存储为…」：弹系统保存面板让用户选择位置。
    private func saveAs(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.directoryURL = settings.saveDirectory
        panel.canCreateDirectories = true
        panel.allowedContentTypes = settings.saveFormat == .png ? [.png] : [.jpeg]
        let base = FilenameTemplate.makeName(
            template: settings.effectiveFilenameTemplate,
            date: Date()
        )
        panel.nameFieldStringValue = "\(base).\(settings.saveFormat.fileExtension)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data?
            switch settings.saveFormat {
            case .png: data = CaptureOutput.pngData(image)
            case .jpeg: data = CaptureOutput.jpegData(image, quality: settings.jpegQuality)
            }
            guard let data else { throw CaptureOutputError.encodingFailed }
            try data.write(to: url, options: .atomic)
            didSave(to: url)
        } catch {
            logger.error("save failed: \(error.localizedDescription)")
        }
    }

    /// 落盘后的统一收尾：记入最近截图 + 图标闪烁 + 通知。
    private func didSave(to url: URL) {
        settings.recordCapture(url)
        logger.notice("saved capture to \(url.path, privacy: .public)")
        menuBar?.flashCaptureFeedback()
        if settings.showSaveNotification {
            notifier.notifySaved(fileURL: url)
        }
    }

    /// 托盘历史面板。
    private func showHistory() {
        if historyPanel == nil {
            let controller = HistoryPanelController()
            controller.itemsProvider = { [weak self] in self?.historyItems() ?? [] }
            controller.onSelect = { [weak self] item in
                guard let self else { return }
                if let cgImage = item.cgImage {
                    self.openAnnotationEditor(cgImage)
                    return
                }
                guard let url = item.url,
                    let image = NSImage(contentsOf: url),
                    let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { return }
                self.openAnnotationEditor(cgImage)
            }
            historyPanel = controller
        }
        historyPanel?.toggle()
    }

    /// 会话内截图（最新在前）+ 磁盘上保存过的截图，按时间倒序。
    private func historyItems() -> [HistoryItem] {
        let saved = settings.recentCaptureURLs.map { url -> HistoryItem in
            HistoryItem(
                id: url.path,
                date: FilenameTemplate.captureDate(of: url),
                image: NSImage(contentsOf: url),
                url: url,
                cgImage: nil
            )
        }
        let merged = sessionHistory + saved
        return merged
            .sorted { $0.date > $1.date }
            .prefix(40)
            .map { $0 }
    }

    /// 记录一次截图到会话历史。
    private func recordHistory(_ image: CGImage) {
        let item = HistoryItem(
            id: UUID().uuidString,
            date: Date(),
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            url: nil,
            cgImage: image
        )
        sessionHistory.insert(item, at: 0)
        if sessionHistory.count > 40 { sessionHistory.removeLast(sessionHistory.count - 40) }
    }

    /// 打开截图保存目录（不存在则先创建）。
    private func openSaveFolder() {
        let directory = settings.saveDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(directory)
        } catch {
            logger.error("open save folder failed: \(error.localizedDescription)")
        }
    }

    /// 启动时把「登录时启动」状态同步给系统，避免设置与系统实际状态不一致。
    private func setUpLaunchAtLogin() {
        LaunchAtLogin.setEnabled(settings.launchAtLogin)
    }

    // MARK: - Support

    private func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(settings: settings)
        }
        onboarding?.present()
    }

    private func showSettings() {
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
    private func presentHotkeyFailure(_ hotkey: Hotkey, action: HotkeyAction) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(action.title)」的快捷键 \(hotkey.displayString) 注册失败"
        alert.informativeText = "该组合键可能已被系统、其它 App 或本 App 的其它动作占用，已恢复为原来的快捷键。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentCaptureFailure(_ error: Error) {
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
