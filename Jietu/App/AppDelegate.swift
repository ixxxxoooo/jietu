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

        if !ScreenCapturePermission.isGranted {
            logger.notice("screen recording permission missing, showing onboarding")
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
        menuBar.onOpenSystemSettings = { ScreenCapturePermission.openSystemSettings() }
        menuBar.onOpenOnboarding = { [weak self] in self?.showOnboarding() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.refresh()
        self.menuBar = menuBar
    }

    private func setUpHotkeys() {
        hotkeys.unregisterAll()
        let hotkey = settings.hotkeyAreaCapture
        let id = hotkeys.register(hotkey) { [weak self] in
            self?.handleAreaCapture()
        }
        if id == nil {
            logger.error("failed to register hotkey \(hotkey.displayString, privacy: .public)")
        } else {
            logger.notice("registered hotkey \(hotkey.displayString, privacy: .public)")
        }
    }

    private func setUpQuickAccess() {
        quickAccess.onCopy = { image in
            CaptureOutput.copyToPasteboard(image)
        }
        quickAccess.onSave = { [weak self] image in
            self?.save(image)
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
                    session: CaptureSession(snapshots: snapshots, windows: windows)
                )
            } catch {
                presentCaptureFailure(error)
            }
        }
    }

    private func handleOverlayOutcome(_ outcome: OverlayCoordinator.Outcome) {
        switch outcome {
        case .cancelled:
            break
        case .captured(let image, let displayID):
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

        quickAccess.present(
            image: image,
            onDisplay: displayID,
            saveDirectory: settings.saveDirectory
        )
    }

    private func save(_ image: CGImage) {
        do {
            let url = try CaptureOutput.save(image, toDirectory: settings.saveDirectory)
            logger.notice("saved capture to \(url.path, privacy: .public)")
        } catch {
            logger.error("save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Support

    private func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController()
        }
        onboarding?.present()
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
