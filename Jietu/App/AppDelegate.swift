import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.liwenjiao.jietu", category: "app")

    private let settings = SettingsStore()
    private let hotkeys = HotkeyCenter()
    private let capture = CaptureEngine()
    private let overlays = OverlayCoordinator()
    private let quickAccess = QuickAccessPanelController()
    private var menuBar: MenuBarController?
    private var onboarding: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?
    private var annotationEditors: [AnnotationEditorWindowController] = []
    private var hotkeyRegistrationID: UInt32?
    /// 当前已生效的区域截图热键，注册失败时用它回滚。
    private var activeHotkey: Hotkey?

    /// 启动时已有权限 = 当前进程可直接截图。
    ///
    /// 关键语义：`CGPreflightScreenCaptureAccess()` 会在用户刚授权后立刻返回 true，
    /// 但 ScreenCaptureKit 在**同一个进程**里仍然拿不到内容，必须重启。
    /// 所以这个值在启动时确定后就不再改，Onboarding 只负责提示重启。
    private(set) var hasUsableScreenCapturePermission = ScreenCapturePermission.isGranted

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        // 自检模式：不建菜单栏、不注册热键，跑完自己退出。
        if CaptureSelfTest.handleCommandLineIfNeeded() {
            return
        }
        #endif

        setUpMenuBar()
        setUpHotkeys()
        setUpQuickAccess()
        setUpLaunchAtLogin()

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
        menuBar.onOpenRecent = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        menuBar.onClearRecents = { [weak self] in self?.settings.clearRecentCaptures() }
        menuBar.onOpenFolder = { [weak self] in self?.openSaveFolder() }
        menuBar.onOpenSystemSettings = { ScreenCapturePermission.openSystemSettings() }
        menuBar.onOpenOnboarding = { [weak self] in self?.showOnboarding() }
        menuBar.onOpenSettings = { [weak self] in self?.showSettings() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.recentProvider = { [weak self] in self?.settings.recentCaptureURLs ?? [] }
        menuBar.refresh()
        self.menuBar = menuBar
    }

    private func setUpHotkeys() {
        applyAreaCaptureHotkey(settings.hotkeyAreaCapture)
    }

    /// 注销旧热键并注册新热键。
    ///
    /// Carbon 热键不能原地修改，设置页改了组合键只能走这条路径重注册。
    /// 注册失败（多半是被别的 App 占用）时会回滚到上一个可用组合键并返回 false。
    @discardableResult
    private func applyAreaCaptureHotkey(_ hotkey: Hotkey) -> Bool {
        let previous = activeHotkey

        if let hotkeyRegistrationID {
            hotkeys.unregister(hotkeyRegistrationID)
            self.hotkeyRegistrationID = nil
        }

        let id = hotkeys.register(hotkey) { [weak self] in
            self?.handleAreaCapture()
        }
        if let id {
            hotkeyRegistrationID = id
            activeHotkey = hotkey
            logger.notice("registered hotkey \(hotkey.displayString, privacy: .public)")
            return true
        }

        logger.error("failed to register hotkey \(hotkey.displayString, privacy: .public)")
        // 回滚：把上一个可用的组合键重新注册回来，避免用户彻底失去快捷键。
        if let previous {
            hotkeyRegistrationID = hotkeys.register(previous) { [weak self] in
                self?.handleAreaCapture()
            }
        }
        return false
    }

    private func setUpQuickAccess() {
        quickAccess.autoCloseDelay = settings.quickAccessAutoCloseDelay
        quickAccess.position = settings.quickAccessPosition
        quickAccess.onCopy = { image in
            CaptureOutput.copyToPasteboard(image)
        }
        quickAccess.onSave = { [weak self] image in
            self?.save(image)
        }
        quickAccess.onAnnotate = { [weak self] image in
            self?.openAnnotationEditor(image)
        }
        quickAccess.onPin = { image in
            PinWindowController.pin(image: image, on: NSScreen.main)
        }
        overlays.onFinish = { [weak self] outcome in
            self?.handleOverlayOutcome(outcome)
        }
    }

    // MARK: - Capture flow

    private func handleAreaCapture() {
        guard !overlays.isPresenting else { return }

        // 权限是启动后才有 → 当前进程用不了，直接引导重启。
        guard hasUsableScreenCapturePermission else {
            logger.notice("capture requested without usable permission")
            showOnboarding()
            return
        }

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
        guard hasUsableScreenCapturePermission else {
            showOnboarding()
            return
        }

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
        guard hasUsableScreenCapturePermission else {
            showOnboarding()
            return
        }

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
            break
        case .captured(let image, let displayID, let screenRect, let annotated):
            if annotated {
                // 已在遮罩里就地标注完成，直接走交付流程。
                deliver(image, onDisplay: displayID)
            } else {
                handleCaptured(image, onDisplay: displayID, screenRect: screenRect)
            }
        }
    }

    /// 截图完成后的分流：就地编辑 / 浮窗预览。
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
            openAnnotationEditor(image, anchor: screenRect)
        case .window:
            deliver(image, onDisplay: displayID)
        }
    }

    private func deliver(_ image: CGImage, onDisplay displayID: CGDirectDisplayID) {
        logger.notice("delivering \(image.width)x\(image.height) capture")

        if settings.playShutterSound {
            CaptureOutput.playShutterSound()
        }
        if settings.copyToClipboard, !CaptureOutput.copyToPasteboard(image) {
            logger.error("clipboard write failed")
        }
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
    /// - Parameter anchor: 选区在屏幕上的矩形（就地编辑时把窗口放到选区附近）。
    private func openAnnotationEditor(_ image: CGImage, anchor: CGRect? = nil) {
        let controller = AnnotationEditorWindowController(image: image, anchor: anchor)
        controller.onCopy = { rendered in
            CaptureOutput.copyToPasteboard(rendered)
        }
        controller.onSave = { [weak self] rendered in
            self?.save(rendered)
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
                quality: settings.jpegQuality
            )
            settings.recordCapture(url)
            logger.notice("saved capture to \(url.path, privacy: .public)")
        } catch {
            logger.error("save failed: \(error.localizedDescription)")
        }
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
            onboarding = OnboardingWindowController()
        }
        onboarding?.present()
    }

    private func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(settings: settings)
            controller.onHotkeyChange = { [weak self] hotkey in
                guard let self else { return }
                guard self.applyAreaCaptureHotkey(hotkey) else {
                    // 回滚设置里的组合键，并提示占用。
                    if let active = self.activeHotkey, self.settings.hotkeyAreaCapture != active {
                        self.settings.hotkeyAreaCapture = active
                    }
                    self.presentHotkeyFailure(hotkey)
                    return
                }
            }
            settingsWindow = controller
        }
        settingsWindow?.present()
    }

    /// 热键被占用时的提示。
    private func presentHotkeyFailure(_ hotkey: Hotkey) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "快捷键 \(hotkey.displayString) 注册失败"
        alert.informativeText = "该组合键可能已被系统或其它 App 占用，已恢复为原来的快捷键。"
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
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "好")

        if alert.runModal() == .alertFirstButtonReturn {
            ScreenCapturePermission.openSystemSettings()
        }
    }
}
