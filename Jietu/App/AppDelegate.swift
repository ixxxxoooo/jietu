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
        menuBar.onOpenSystemSettings = { ScreenCapturePermission.openSystemSettings() }
        menuBar.onOpenOnboarding = { [weak self] in self?.showOnboarding() }
        menuBar.onOpenSettings = { [weak self] in self?.showSettings() }
        menuBar.onReregisterPermission = { [weak self] in
            self?.reRegisterScreenCapturePermission()
        }
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
            self?.handleOverlayOutcome(outcome)
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
        overlays.onRegionPicked = { [weak self] snapshot, localRect in
            self?.startScrollingCapture(snapshot: snapshot, localRect: localRect)
        }
    }

    // MARK: - Capture flow

    /// 需要「屏幕录制」权限的入口统一走这里。
    ///
    /// 每次都**现读**，不缓存启动时的快照——用户刚在系统设置里勾完就回来时，
    /// 缓存的旧值会让入口一直说「没权限」。不可用就打开权限引导：
    /// 引导页里既能看到实时状态，也有「重新检测」和「重启 Jietu」两个出口。
    /// 「重新注册「屏幕录制」权限…」：清掉本 App 的旧记录再重新申请，
    /// 让它重新出现在系统设置的列表里。清掉后必须重新授权 + 重启才生效。
    private func reRegisterScreenCapturePermission() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "重新注册「屏幕录制」权限？"
        alert.informativeText =
            "会先清掉本 App 在「屏幕录制」里的旧记录，再重新申请一次，"
            + "让它重新出现在系统设置的列表里。\n"
            + "清掉之后需要重新勾选，并重启 Jietu 才会生效。"
        alert.addButton(withTitle: "重新注册")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        ScreenCapturePermission.reRegister()
        ScreenCapturePermission.openSystemSettings()
        // 授权后的状态在本次进程里不会刷新，直接引导重启。
        presentRelaunchPrompt()
    }

    /// 屏幕录制的授权只在授权之后启动的进程里生效，需要重启时统一走这里。
    private func presentRelaunchPrompt() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "需要重启 Jietu"
        alert.informativeText = "macOS 的屏幕录制授权只在授权之后启动的进程里生效，重启后即可正常截图。"
        alert.addButton(withTitle: "重启 Jietu")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenCapturePermission.relaunchApp()
        }
    }

    private func requireScreenCapturePermission() -> Bool {
        guard !ScreenCapturePermission.isGranted else { return true }
        logger.notice("capture requested without screen recording permission")
        showOnboarding()
        return false
    }

    private func handleAreaCapture() {
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

    /// 滚动长图：先用遮罩取一块选区，再由 `ScrollingCaptureSession` 连续采样拼接。
    private func handleScrollingCapture() {
        guard !overlays.isPresenting, scrollingSession == nil else { return }
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

    /// 选区确定后启动采样：控制条浮在选区下方，用户手动滚动内容。
    private func startScrollingCapture(snapshot: DisplaySnapshot, localRect: CGRect) {
        overlays.purpose = .screenshot

        let screenFrame = snapshot.screenFrameInPoints
        // local（原点左下）→ 显示器坐标（原点左上），SCK 的 sourceRect 用后者。
        let region = CGRect(
            x: localRect.minX,
            y: screenFrame.height - localRect.maxY,
            width: localRect.width,
            height: localRect.height
        )
        guard region.width >= 8, region.height >= 8 else {
            presentCaptureFailure(CaptureError.emptyRegion)
            return
        }

        let session = ScrollingCaptureSession(
            engine: capture,
            target: ScrollingCaptureSession.Target(
                displayID: snapshot.displayID,
                regionInPoints: region
            )
        )
        let panel = ScrollingCapturePanelController()
        scrollingSession = session
        scrollingPanel = panel
        isScrollingCancelled = false

        session.onProgress = { [weak panel] height in
            panel?.update(height: height)
        }
        panel.onFinish = { [weak self] in
            self?.scrollingSession?.stop()
        }
        panel.onCancel = { [weak self] in
            self?.isScrollingCancelled = true
            self?.scrollingSession?.stop()
        }
        panel.present(
            near: CGRect(
                x: screenFrame.minX + localRect.minX,
                y: screenFrame.minY + localRect.minY,
                width: localRect.width,
                height: localRect.height
            )
        )
        registerScrollingEscapeMonitor()

        Task { @MainActor in
            let image = await session.run()
            finishScrollingCapture(image: image, displayID: snapshot.displayID)
        }
    }

    /// Esc 结束采样（控制条未必拿得到焦点，这里再兜一层）。
    private func registerScrollingEscapeMonitor() {
        removeScrollingEscapeMonitor()
        scrollingEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.scrollingSession != nil else { return event }
            self.scrollingSession?.stop()
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

        let cancelled = isScrollingCancelled
        isScrollingCancelled = false
        guard !cancelled else { return }

        guard let image else {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "没有捕获到滚动内容"
            alert.informativeText = "请框选可滚动的区域，然后缓慢、匀速地滚动内容再试一次。"
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
            // 截完立刻进剪贴板：就地编辑期间（甚至取消编辑）也能直接去别处粘贴。
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
    /// - Parameter anchor: 选区在屏幕上的矩形（就地编辑时把窗口放到选区附近）。
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
