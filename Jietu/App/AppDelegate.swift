import AppKit
import AVFoundation
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
    /// 正在进行的录屏会话与控制条 / 红框。
    private var recordingEngine: RecordingEngine?
    private var recordingHUD: RecordingControlPanel?
    private var recordingBorder: RecordingBorderPanel?
    private var recordingKeyMonitors: [Any] = []
    /// 已录时长（秒，暂停不计）：收工时的通知里要写。
    private var recordingElapsed: TimeInterval = 0
    /// 录的是哪块屏：收工后的浮窗要落回同一块屏（和截图一个规矩）。
    private var recordingDisplayID: CGDirectDisplayID?
    /// 最近截图自检的报告行（`popUp` 里的定时器闭包没法捕局部变量）。
    private var recentMenuReport: [String] = []
    /// 正在被自检弹出的子菜单 / 这一张的名字（同上：不能让定时器闭包捕获 NSMenu）。
    private var recentMenuUnderTest: NSMenu?
    private var recentMenuShotName: String?
    /// 框选好了、**还没点「开始」**的那一档：红框 + 控制条先停着（`phase = .ready`）。
    private var pendingRecording: (displayID: CGDirectDisplayID, region: CGRect)?

    /// 滚动长图的右侧实时预览。
    private var scrollingPreview: ScrollingPreviewPanel?
    /// 本次滚动长图的选区（含三套换算好的坐标）：用户中途改选区时跟着更新。
    private var scrollingTarget: CaptureRegionTarget?
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
        #endif

        if !ScreenCapturePermission.isGranted {
            logger.notice("screen recording permission missing, showing onboarding")
            // 启动时不主动向系统弹窗申请授权，交由用户在引导页中点击「授权屏幕录制」时手动触发
            showOnboarding()
        }
    }

    #if DEBUG
    /// 自检（要**真 App 接线**）：就地编辑工具栏点「滚动截图 → 手动滚动」，
    /// 看滚动会话有没有真的起来：控制条在、遮罩切成取景框（鼠标穿透）、右侧预览挂上。
    ///
    /// 与 `--selftest-inline-scroll` 分工：那条验「工具栏 → 模式 + 选区交出去」，
    /// 这条验「交出去之后 AppDelegate 真的把会话跑起来」。自检进程里没有 AppDelegate，
    /// 所以这条必须挂在真启动流程上（见 `CaptureSelfTest.appLevelInlineScrollFlag`）。
    /// 自检（要**真 App 接线**）：菜单「录屏…」→ 遮罩框一块区域 → 红框 + 控制条起来 → 点完成 → 落盘。
    ///
    /// 这条验的是接线（选区域之后 AppDelegate 有没有真的把它变成一次录制、收工有没有真落盘），
    /// 「最近截图」子菜单：先验**重启后还有数据**，再把两种状态各弹出来拍一张。
    ///
    /// 走这条自检是因为菜单的渲染只有真弹出来才拍得到；而「重启后还有数据」这件事，
    /// 这里用「另开一个 HistoryStore 读同一个目录」来模拟（同一进程里就能验）。
    /// 全程主线程同步跑（菜单 `popUp` 会开自己的事件跟踪循环），截图用系统的 `screencapture`：
    /// 定时器得挂到 `.common` 模式，否则事件跟踪期间不会触发。
    private func runRecentMenuAppTest() {
        recentMenuReport = []
        guard let menuBar else {
            CaptureSelfTest.finish(["菜单栏还没建起来"], code: 1)
            return
        }

        // 1. 记一张（走真实落盘那条路），再用**另一个实例**读同一个目录：相当于重启。
        let image = (try? CaptureSelfTest.makeTestImage(width: 800, height: 500)) ?? nil
        var recordedID: String?
        if let image {
            recordedID = HistoryStore.shared.record(image)?.id
        }
        let reopened = HistoryStore(directory: HistoryStore.shared.directoryForTesting)
        let survived = recordedID != nil && reopened.entries.contains { $0.id == recordedID }
        recentMenuReport.append(
            "刚记一张 → 重开历史库：条目=\(reopened.entries.count)，刚记那条还在=\(survived ? "是" : "**否**")"
        )
        recentMenuReport.append("最近截图菜单项数=\(historyItems().count)")

        // 菜单上的快捷键：拿**当前真实设置**刷一遍，看每一项显示成什么。
        menuBar.refresh()
        func shortcut(_ title: String) -> String {
            guard let item = menuBar.menuForTesting.items.first(where: { $0.title == title }),
                !item.keyEquivalent.isEmpty
            else { return "—" }
            var flags = ""
            if item.keyEquivalentModifierMask.contains(.control) { flags += "⌃" }
            if item.keyEquivalentModifierMask.contains(.option) { flags += "⌥" }
            if item.keyEquivalentModifierMask.contains(.shift) { flags += "⇧" }
            if item.keyEquivalentModifierMask.contains(.command) { flags += "⌘" }
            return flags + item.keyEquivalent.uppercased()
        }
        recentMenuReport.append(
            "菜单快捷键："
                + ["区域截图", "窗口截图", "全屏截图", "滚动长图…", "区域录制", "窗口录制", "全屏录制"]
                .map { "\($0)=\(shortcut($0))" }
                .joined(separator: "，")
        )

        // 1.5 走**真实那条路**（deliver）截一张：菜单项只能多一条，不能重复。
        //    临时关掉「保存到磁盘」：这一步只是验历史记录，别往用户的截图文件夹里塞测试图。
        if let image {
            let savedToDisk = settings.saveToDisk
            settings.saveToDisk = false
            defer { settings.saveToDisk = savedToDisk }

            let before = historyItems().count
            deliver(image, onDisplay: CGMainDisplayID())
            let after = historyItems().count
            recentMenuReport.append(
                "真实截一张：菜单项 \(before) → \(after)（多了 \(after - before) 条，"
                    + "重复=\(after - before > 1 ? "**是**" : "否")）"
            )
            // deliver 会弹浮窗：收掉，别干扰后面。
            quickAccess.dismiss()
        }

        // 2. 空历史：该是一条原生灰字「暂无最近截图」。
        menuBar.historyItemsProvider = { [] }
        menuBar.menuNeedsUpdate(menuBar.recentMenuForTesting)
        let emptyItems = menuBar.recentMenuForTesting.items
        recentMenuReport.append(
            "空历史：条目=\(emptyItems.count)，标题=\(emptyItems.first?.title ?? "—")"
                + "，可点=\(emptyItems.first?.isEnabled == true)"
                + "，是卡片视图=\(emptyItems.first?.view != nil)"
        )
        popAndShootRecentMenu(menuBar.recentMenuForTesting, name: "empty")

        // 3. 有数据：卡片（把真的 provider 装回去——它读的就是 HistoryStore）。
        menuBar.historyItemsProvider = { [weak self] in self?.historyItems() ?? [] }
        menuBar.menuNeedsUpdate(menuBar.recentMenuForTesting)
        recentMenuReport.append(
            "有数据：条目=\(menuBar.recentMenuForTesting.items.count)"
                + "，是卡片视图=\(menuBar.recentMenuForTesting.items.first?.view != nil)"
        )
        popAndShootRecentMenu(menuBar.recentMenuForTesting, name: "data")

        // 4. 顶层菜单也弹出来拍一张：快捷键显示 + 截图/录制之间的分隔线一起看。
        popAndShootRecentMenu(menuBar.menuForTesting, name: "main")

        let noDuplicates = !recentMenuReport.contains { $0.contains("重复=**是**") }
        let passed = survived && noDuplicates
        recentMenuReport.append("RESULT: \(passed ? "PASS" : "FAIL")")
        CaptureSelfTest.finish(recentMenuReport, code: passed ? 0 : 1)
    }

    /// 弹出「最近截图」子菜单一秒，拍一张系统截图再收掉。
    ///
    /// 菜单挂在实例上而不是让定时器闭包捕获：`NSMenu` 不是 `Sendable`，
    /// 让 `@Sendable` 的定时器闭包捕它会直接报并发错误。
    private func popAndShootRecentMenu(_ menu: NSMenu, name: String) {
        recentMenuUnderTest = menu
        recentMenuShotName = name
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishRecentMenuShot() }
        }
        RunLoop.current.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: CGPoint(x: 420, y: 420), in: nil)
    }

    private func finishRecentMenuShot() {
        shootRecentMenu(recentMenuShotName ?? "menu")
        recentMenuUnderTest?.cancelTracking()
        recentMenuUnderTest = nil
    }

    private func shootRecentMenu(_ name: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jietu-recent-menu-\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", url.path]
        do {
            try process.run()
            process.waitUntilExit()
            recentMenuReport.append("\(name) 截图 -> \(url.path)")
        } catch {
            recentMenuReport.append("\(name) 截图失败：\(error.localizedDescription)")
        }
    }

    /// 引擎本身的画质 / 时长 / 暂停由 `--selftest-record` 验。
    private func runRecordingAppTest() {
        Task { @MainActor in
            var report: [String] = []
            var budgets: [(label: String, milliseconds: Double?, limit: Double)] = []
            let savedDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("jietu-record-apptest-\(UUID().uuidString)", isDirectory: true)
            // **改过的设置一律还回去**：`saveDirectory` 是落 UserDefaults 的，
            // 自检把目录指到临时目录又不还原的话，用户的截图会一直往一个（跑完就被删掉的）
            // 临时目录里存——「最近截图」永远是空的，正是这么来的。
            let previousSaveDirectory = settings.saveDirectory
            let previousShowSaveNotification = settings.showSaveNotification
            defer {
                settings.saveDirectory = previousSaveDirectory
                settings.showSaveNotification = previousShowSaveNotification
                try? FileManager.default.removeItem(at: savedDirectory)
            }
            do {
                // 落盘目录指到临时目录，别污染用户真实的截图文件夹。
                settings.saveDirectory = savedDirectory
                settings.showSaveNotification = false

                func post(_ type: CGEventType, at point: CGPoint) {
                    CGEvent(
                        mouseEventSource: CGEventSource(stateID: .hidSystemState),
                        mouseType: type,
                        mouseCursorPosition: point,
                        mouseButton: .left
                    )?.post(tap: .cghidEventTap)
                }

                // 1. 走菜单那条路：进遮罩，等用户框区域。
                handleScreenRecording(mode: .region)
                try? await Task.sleep(for: .milliseconds(900))
                report.append("遮罩弹出了=\(overlays.isPresenting ? "是" : "**否**")")

                // 2. 注入一次拖拽当作「框好区域」。
                let start = CGPoint(x: 420, y: 320)
                let end = CGPoint(x: 980, y: 760)
                post(.mouseMoved, at: CGPoint(x: 300, y: 220))
                try? await Task.sleep(for: .milliseconds(150))
                post(.mouseMoved, at: start)
                try? await Task.sleep(for: .milliseconds(120))
                post(.leftMouseDown, at: start)
                for step in 1...6 {
                    let t = CGFloat(step) / 6
                    post(
                        .leftMouseDragged,
                        at: CGPoint(
                            x: start.x + (end.x - start.x) * t,
                            y: start.y + (end.y - start.y) * t
                        )
                    )
                    try? await Task.sleep(for: .milliseconds(30))
                }
                post(.leftMouseUp, at: end)
                try? await Task.sleep(for: .milliseconds(1200))

                // 2.5 选完区域应当**停在待开始**：红框 + 控制条都在，但还没开录。
                let waiting = recordingEngine == nil && pendingRecording != nil
                let hudUp = recordingHUD?.isVisible ?? false
                let borderUp = recordingBorder?.isVisible ?? false
                let overlayGone = !overlays.isPresenting
                report.append(
                    "选区交出去之后：会话=\(recordingEngine == nil ? "**还没开录**" : "**已经开录了**")"
                        + "（待开始=\(waiting ? "是" : "否")）"
                        + "，控制条=\(hudUp ? "可见" : "**不可见**")"
                        + "，红框=\(borderUp ? "可见" : "**不可见**")"
                        + "，遮罩=\(overlayGone ? "已收" : "**还在**")"
                )
                budgets.append(("选完停在待开始（没自动开录）", waiting ? 0 : nil, 0))
                budgets.append(("控制条可见", hudUp ? 0 : nil, 0))
                budgets.append(("红框可见", borderUp ? 0 : nil, 0))
                // 待开始那条控制条长什么样：截一张（「准备录制」+ 取消 + 开始）。
                if let shots = try? await capture.captureAllDisplays(excludingOwnApplication: false),
                    let shot = shots.first(where: { $0.displayID == NSScreen.main?.jietu_displayID })
                        ?? shots.first
                {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("jietu-recording-ready.png")
                    try? CaptureSelfTest.writePNG(shot.image, to: url)
                    report.append("待开始截图 -> \(url.path)")
                }

                // 2.6 点控制条上的「开始」——这才真开录。
                if let startFrame = recordingHUD?.screenFrame(of: .start) {
                    // 面板给的是 AppKit 全局坐标（原点左下），注入事件要的是 cg（原点左上）。
                    let center = CGPoint(
                        x: startFrame.midX,
                        y: DisplayGeometry.referenceHeight - startFrame.midY
                    )
                    post(.mouseMoved, at: center)
                    try? await Task.sleep(for: .milliseconds(150))
                    post(.leftMouseDown, at: center)
                    try? await Task.sleep(for: .milliseconds(70))
                    post(.leftMouseUp, at: center)
                } else {
                    report.append("控制条上**找不到「开始」按钮**")
                }
                try? await Task.sleep(for: .milliseconds(500))
                let engineUp = recordingEngine != nil
                report.append("点「开始」之后：会话=\(engineUp ? "在录" : "**没起来**")")
                budgets.append(("点开始才开录", engineUp ? 0 : nil, 0))

                // 3. 让画面动起来（不动的话 SCK 不出帧，成片可能是空的），再点「完成」。
                for index in 0..<10 {
                    let t = CGFloat(index) * 0.6
                    post(
                        .mouseMoved,
                        at: CGPoint(
                            x: (start.x + end.x) / 2 + cos(t) * 160,
                            y: (start.y + end.y) / 2 + sin(t) * 100
                        )
                    )
                    try? await Task.sleep(for: .milliseconds(90))
                }
                // 抓一张运行中的截图：好亲眼看看控制条 / 红框长什么样。
                if let shots = try? await capture.captureAllDisplays(excludingOwnApplication: false),
                    let shot = shots.first(where: { $0.displayID == NSScreen.main?.jietu_displayID })
                        ?? shots.first
                {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("jietu-recording-hud.png")
                    try? CaptureSelfTest.writePNG(shot.image, to: url)
                    report.append("运行中截图 -> \(url.path)")
                }
                let stopAt = CFAbsoluteTimeGetCurrent()
                if let engine = recordingEngine {
                    await engine.stop()
                }
                try? await Task.sleep(for: .milliseconds(800))
                let elapsed = (CFAbsoluteTimeGetCurrent() - stopAt) * 1000

                let files = (try? FileManager.default.contentsOfDirectory(
                    at: savedDirectory, includingPropertiesForKeys: nil
                )) ?? []
                let mp4 = files.first { $0.pathExtension == "mp4" }
                var duration: Double = -1
                if let mp4 {
                    duration = (try? await AVURLAsset(url: mp4).load(.duration)).map {
                        CMTimeGetSeconds($0)
                    } ?? -1
                }
                report.append(
                    "点完成 → 落盘：文件=\(mp4?.lastPathComponent ?? "**没有**")"
                        + String(format: "，时长 %.2fs", duration)
                        + "，控制条=\(recordingHUD == nil ? "已收" : "**没收**")"
                )
                budgets.append(("落盘出 mp4", mp4 != nil ? 0 : nil, 0))
                budgets.append(("成片有内容（时长 > 0.2s）", duration > 0.2 ? 0 : nil, 0))
                budgets.append(("收工后控制条收掉", recordingHUD == nil ? 0 : nil, 0))
                report.append(String(format: "「完成」→ 收工耗时 %.0f ms", elapsed))

                // 4. 收工后浮窗里该出现一张**视频卡**（封面帧 + 时长）——截图看一眼，也验它真在。
                var cardUp = false
                var cardSize = CGSize.zero
                let cardScreen = NSScreen.main?.visibleFrame ?? .zero
                for _ in 0..<40 {  // 最多等 4s：封面要解码，卡片还有 0.26s 侧滑进场
                    if let panel = quickAccess.panelsForTesting.last {
                        cardSize = panel.frame.size
                        // 「出现」= 真的停在屏幕上了：进场是从屏幕外滑进来的，
                        // 一插入就算数的话会拍到一张还在屏幕外、alpha 还是 0 的空镜。
                        cardUp = quickAccess.isVisible
                            && panel.alphaValue >= 0.99
                            && panel.frame.minX >= cardScreen.minX
                            && panel.frame.maxX <= cardScreen.maxX
                        if cardUp { break }
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                report.append(
                    "收工后的浮窗：\(cardUp ? "出现" : "**没出现**")"
                        + "，卡片 \(Int(cardSize.width))×\(Int(cardSize.height))"
                )
                budgets.append(("收工后浮窗出现视频卡", cardUp ? 0 : nil, 0))
                if cardUp,
                    let shots = try? await capture.captureAllDisplays(excludingOwnApplication: false),
                    let shot = shots.first(where: { $0.displayID == NSScreen.main?.jietu_displayID })
                        ?? shots.first
                {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("jietu-recording-card.png")
                    try? CaptureSelfTest.writePNG(shot.image, to: url)
                    report.append("视频卡截图 -> \(url.path)")
                }
                // 4.5 视频卡上的两处「预览」：点空白处 / 点播放按钮，都该交给系统「预览」。
                if let panel = quickAccess.panelsForTesting.last, cardUp {
                    let cardFrame = panel.frame

                    @MainActor func clickCard(at local: CGPoint, label: String) {
                        let appKit = CGPoint(
                            x: cardFrame.minX + local.x, y: cardFrame.minY + local.y
                        )
                        let cg = CGPoint(
                            x: appKit.x, y: DisplayGeometry.referenceHeight - appKit.y
                        )
                        post(.mouseMoved, at: cg)
                        Thread.sleep(forTimeInterval: 0.18)
                        post(.leftMouseDown, at: cg)
                        Thread.sleep(forTimeInterval: 0.07)
                        post(.leftMouseUp, at: cg)
                        _ = label
                    }

                    // 悬停态截一张：中央该是「播放」胶囊、左下是「保存」圆盘。
                    let hoverPoint = CGPoint(
                        x: cardFrame.midX,
                        y: DisplayGeometry.referenceHeight - cardFrame.midY
                    )
                    post(.mouseMoved, at: hoverPoint)
                    try? await Task.sleep(for: .milliseconds(400))
                    if let shots = try? await capture.captureAllDisplays(excludingOwnApplication: false),
                        let shot = shots.first(where: { $0.displayID == NSScreen.main?.jietu_displayID })
                            ?? shots.first
                    {
                        let url = URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("jietu-recording-card-hover.png")
                        try? CaptureSelfTest.writePNG(shot.image, to: url)
                        report.append("视频卡悬停截图 -> \(url.path)")
                    }

                    // 先按真接线点一次「播放」：看 macOS 自带的「预览」有没有到前台。
                    let playRect = QuickAccessControlsView.frame(of: .play, in: cardFrame.size)
                    clickCard(
                        at: CGPoint(x: playRect.midX, y: playRect.midY), label: "播放按钮"
                    )
                    try? await Task.sleep(for: .milliseconds(3500))
                    let quickLookUp = VideoQuickLookPresenter.shared.isVisible
                    let qlFrame = VideoQuickLookPresenter.shared.panelFrame
                    report.append(
                        "快速查看面板：\(Int(qlFrame.width))×\(Int(qlFrame.height))"
                            + "，预览项=\(VideoQuickLookPresenter.shared.currentItemName ?? "—")"
                    )
                    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "—"
                    report.append(
                        "点「播放」后：快速查看面板=\(quickLookUp ? "已弹出" : "**没弹**")，最前面=\(front)"
                    )
                    budgets.append(("点播放 → 弹出系统快速查看", quickLookUp ? 0 : nil, 0))
                    if let shots = try? await capture.captureAllDisplays(excludingOwnApplication: false),
                        let shot = shots.first(where: { $0.displayID == NSScreen.main?.jietu_displayID })
                            ?? shots.first
                    {
                        let url = URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("jietu-recording-quicklook.png")
                        try? CaptureSelfTest.writePNG(shot.image, to: url)
                        report.append("快速查看截图 -> \(url.path)")
                    }
                    VideoQuickLookPresenter.shared.dismiss()

                    // 再验接线：空白处（避开四角按钮与中央「保存」）与播放按钮都要触发同一个动作。
                    var played: [String] = []
                    quickAccess.onPlayVideo = { url in played.append(url.lastPathComponent) }
                    clickCard(
                        at: CGPoint(x: cardFrame.width * 0.15, y: cardFrame.height / 2), label: "空白处"
                    )
                    try? await Task.sleep(for: .milliseconds(400))
                    let afterBlank = played.count
                    clickCard(at: CGPoint(x: playRect.midX, y: playRect.midY), label: "播放按钮")
                    try? await Task.sleep(for: .milliseconds(400))
                    report.append(
                        "视频卡点击：空白处触发=\(afterBlank) 次，播放按钮触发=\(played.count - afterBlank) 次"
                    )
                    budgets.append(("点空白处也走预览", afterBlank >= 1 ? 0 : nil, 0))
                    budgets.append(("点播放按钮走预览", played.count - afterBlank >= 1 ? 0 : nil, 0))

                    // 正中那块：悬停时是「保存」胶囊（把「▶ 0:12」顶掉了）——看看点它到底触发谁。
                    var saved: [String] = []
                    quickAccess.onSaveVideo = { url in saved.append(url.lastPathComponent) }
                    played.removeAll()
                    clickCard(
                        at: CGPoint(x: cardFrame.width / 2, y: cardFrame.height / 2), label: "正中"
                    )
                    try? await Task.sleep(for: .milliseconds(500))
                    report.append("点卡片正中：播放=\(played.count) 保存=\(saved.count)")
                    budgets.append(("点卡片正中走播放（不是保存）", played.count == 1 && saved.isEmpty ? 0 : nil, 0))

                    // 真实使用里浮窗**不是 key window**（用户还在别的 App 里）：再验一遍，
                    // 「第一下点击被用来激活窗口」正是这个 App 踩过无数次的坑。
                    NSApp.deactivate()
                    try? await Task.sleep(for: .milliseconds(600))
                    played.removeAll()
                    clickCard(
                        at: CGPoint(x: cardFrame.width * 0.15, y: cardFrame.height / 2), label: "空白处"
                    )
                    try? await Task.sleep(for: .milliseconds(500))
                    let inactiveBlank = played.count
                    clickCard(at: CGPoint(x: playRect.midX, y: playRect.midY), label: "播放按钮")
                    try? await Task.sleep(for: .milliseconds(500))
                    report.append(
                        "未激活时（浮窗不是 key window）点击：空白处=\(inactiveBlank) 次"
                            + "，播放按钮=\(played.count - inactiveBlank) 次"
                    )
                    budgets.append(("未激活时点空白处也走预览", inactiveBlank >= 1 ? 0 : nil, 0))
                    budgets.append(("未激活时点播放按钮走预览", played.count - inactiveBlank >= 1 ? 0 : nil, 0))
                }

                quickAccess.dismiss()

                // 5. 全屏录制：**不弹遮罩**，鼠标所在那块屏整幅 → 直接停在待开始。
                handleScreenRecording(mode: .fullScreen)
                try? await Task.sleep(for: .milliseconds(900))
                let fullReady = pendingRecording != nil && recordingEngine == nil
                    && !overlays.isPresenting
                let fullBorder = recordingBorder?.isVisible ?? false
                let fullRegion = pendingRecording?.region.size ?? .zero
                report.append(
                    "全屏录制：待开始=\(fullReady ? "是" : "**否**")"
                        + "，遮罩=\(overlays.isPresenting ? "**还在**" : "没弹")"
                        + "，红框=\(fullBorder ? "可见" : "**不可见**")"
                        + "，选框 \(Int(fullRegion.width))×\(Int(fullRegion.height))"
                )
                budgets.append(("全屏录制直接进待开始（不弹遮罩）", fullReady && fullBorder ? 0 : nil, 0))
                cancelRecording()
                try? await Task.sleep(for: .milliseconds(300))

                // 6. 窗口录制：遮罩里点哪个窗口就录哪个（相机光标 + 悬停高亮）。
                let candidates = WindowHitTester.onScreenWindows(excludingPID: getpid())
                    .filter { $0.frameInCGPoints.width > 240 && $0.frameInCGPoints.height > 240 }
                    .sorted { $0.frameInCGPoints.width * $0.frameInCGPoints.height
                        > $1.frameInCGPoints.width * $1.frameInCGPoints.height }
                if let window = candidates.first {
                    handleScreenRecording(mode: .window)
                    try? await Task.sleep(for: .milliseconds(900))
                    let overlayUp = overlays.isPresenting
                    let center = CGPoint(
                        x: window.frameInCGPoints.midX, y: window.frameInCGPoints.midY
                    )
                    post(.mouseMoved, at: center)
                    try? await Task.sleep(for: .milliseconds(200))
                    post(.leftMouseDown, at: center)
                    try? await Task.sleep(for: .milliseconds(80))
                    post(.leftMouseUp, at: center)
                    try? await Task.sleep(for: .milliseconds(700))
                    let windowReady = pendingRecording != nil && recordingEngine == nil
                        && !overlays.isPresenting
                    let windowRegion = pendingRecording?.region.size ?? .zero
                    report.append(
                        "窗口录制：遮罩=\(overlayUp ? "弹了" : "**没弹**")"
                            + "，点窗口后待开始=\(windowReady ? "是" : "**否**")"
                            + "，选框 \(Int(windowRegion.width))×\(Int(windowRegion.height))"
                            + "（窗口 \(Int(window.frameInCGPoints.width))×\(Int(window.frameInCGPoints.height))）"
                    )
                    budgets.append(("窗口录制点窗口进待开始", windowReady ? 0 : nil, 0))
                    cancelRecording()
                    overlays.cancel()
                    try? await Task.sleep(for: .milliseconds(300))
                } else {
                    report.append("窗口录制：屏幕上找不到够大的窗口，跳过")
                }

                // 7. 截图时那条就地工具栏上的「录屏」：拿当前选区直接进待开始（走的是同一条交接）。
                overlays.purpose = .screenshot
                overlays.present(
                    session: CaptureSession(
                        snapshots: try await capture.captureAllDisplays(),
                        windows: WindowHitTester.onScreenWindows(excludingPID: getpid())
                    ),
                    inlineMode: true
                )
                try? await Task.sleep(for: .milliseconds(700))
                let dragStart = CGPoint(x: 360, y: 300)
                let dragEnd = CGPoint(x: 900, y: 700)
                post(.mouseMoved, at: CGPoint(x: 200, y: 160))
                try? await Task.sleep(for: .milliseconds(150))
                post(.mouseMoved, at: dragStart)
                try? await Task.sleep(for: .milliseconds(120))
                post(.leftMouseDown, at: dragStart)
                for step in 1...6 {
                    let t = CGFloat(step) / 6
                    post(
                        .leftMouseDragged,
                        at: CGPoint(
                            x: dragStart.x + (dragEnd.x - dragStart.x) * t,
                            y: dragStart.y + (dragEnd.y - dragStart.y) * t
                        )
                    )
                    try? await Task.sleep(for: .milliseconds(30))
                }
                post(.leftMouseUp, at: dragEnd)
                try? await Task.sleep(for: .milliseconds(1000))

                // 拍一张就地工具栏（选中状态的按钮排布）。
                if let shots = try? await capture.captureAllDisplays(excludingOwnApplication: false),
                    let shot = shots.first(where: { $0.displayID == NSScreen.main?.jietu_displayID })
                        ?? shots.first
                {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("jietu-inline-toolbar.png")
                    try? CaptureSelfTest.writePNG(shot.image, to: url)
                    report.append("就地工具栏截图 -> \(url.path)")
                }

                let toolbarRecord = overlays.debugTriggerRecord(displayID: NSScreen.main?.jietu_displayID ?? 0)
                try? await Task.sleep(for: .milliseconds(800))
                let fromToolbar = pendingRecording != nil && recordingEngine == nil
                    && !overlays.isPresenting
                let toolbarRegion = pendingRecording?.region.size ?? .zero
                report.append(
                    "工具栏「录屏」：触发=\(toolbarRecord ? "是" : "**否**")"
                        + "，待开始=\(fromToolbar ? "是" : "**否**")"
                        + "，遮罩=\(overlays.isPresenting ? "**还在**" : "已收")"
                        + "，选框 \(Int(toolbarRegion.width))×\(Int(toolbarRegion.height))"
                )
                budgets.append(("工具栏「录屏」直接进待开始", fromToolbar ? 0 : nil, 0))
                cancelRecording()
                if overlays.isPresenting { overlays.cancel() }
                try? await Task.sleep(for: .milliseconds(300))

                report.append("延迟预算：")
                var failed = 0
                for budget in budgets {
                    let ok = budget.milliseconds != nil && budget.milliseconds! <= budget.limit
                    if !ok { failed += 1 }
                    report.append("    \(ok ? "✅" : "❌") \(budget.label)")
                }
                report.append("RESULT: \(failed == 0 ? "PASS" : "FAIL（\(failed) 项未达成）")")
                CaptureSelfTest.finish(report, code: failed == 0 ? 0 : 1)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                CaptureSelfTest.finish(report, code: 1)
            }
        }
    }

    private func runInlineScrollAppTest() {
        Task { @MainActor in
            var report: [String] = []
            var budgets: [(label: String, milliseconds: Double?, limit: Double)] = []
            do {
                let snapshots = try await capture.captureAllDisplays()
                guard let snapshot = snapshots.first else { throw CaptureError.noDisplays }
                let displayID = snapshot.displayID
                let screen = NSScreen.screens.first { $0.jietu_displayID == displayID }
                    ?? NSScreen.main ?? NSScreen.screens[0]
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())

                func post(_ type: CGEventType, at point: CGPoint) {
                    CGEvent(
                        mouseEventSource: CGEventSource(stateID: .hidSystemState),
                        mouseType: type,
                        mouseCursorPosition: point,
                        mouseButton: .left
                    )?.post(tap: .cghidEventTap)
                }

                /// 弹遮罩（就地模式）→ 拖一块选区 → 返回选区（本显示器 local 矩形）。
                @MainActor func dragSelection() async -> CGRect? {
                    overlays.purpose = .screenshot
                    overlays.present(
                        session: CaptureSession(snapshots: snapshots, windows: windows),
                        inlineMode: true
                    )
                    try? await Task.sleep(for: .milliseconds(700))

                    let start = CGPoint(x: 320, y: 260)
                    let end = CGPoint(x: 900, y: 700)
                    post(.mouseMoved, at: CGPoint(x: 200, y: 160))
                    try? await Task.sleep(for: .milliseconds(150))
                    post(.mouseMoved, at: start)
                    try? await Task.sleep(for: .milliseconds(120))
                    post(.leftMouseDown, at: start)
                    for step in 1...6 {
                        let t = CGFloat(step) / 6
                        post(
                            .leftMouseDragged,
                            at: CGPoint(
                                x: start.x + (end.x - start.x) * t,
                                y: start.y + (end.y - start.y) * t
                            )
                        )
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                    post(.leftMouseUp, at: end)
                    try? await Task.sleep(for: .milliseconds(600))
                    return overlays.debugSelections
                        .first { $0.displayID == displayID }?.localRect
                }

                @MainActor func waitUntil(
                    _ since: CFAbsoluteTime, timeout: TimeInterval = 1.5,
                    until condition: () -> Bool
                ) async -> Double? {
                    while CFAbsoluteTimeGetCurrent() - since < timeout {
                        if condition() { return (CFAbsoluteTimeGetCurrent() - since) * 1000 }
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    return nil
                }

                // MARK: 一、手动滚动：工具栏点了就开跑
                guard let selection = await dragSelection() else {
                    report.append("error: 就地模式没有形成选区 / 没有工具栏")
                    report.append("RESULT: FAIL")
                    CaptureSelfTest.finish(report, code: 1)
                    return
                }
                report.append("就地选区=\(CaptureSelfTest.describe(selection))")

                var handoff: (mode: ScrollingCaptureSession.Mode, rect: CGRect)?
                overlays.onScrollCapture = { [weak self] snapshot, mode, rect in
                    handoff = (mode, rect)
                    self?.startScrollingCaptureFromInline(
                        snapshot: snapshot, mode: mode, localRect: rect
                    )
                }

                let firedAt = CFAbsoluteTimeGetCurrent()
                let triggered = overlays.debugTriggerScrollCapture(.manual, displayID: displayID)
                let triggerMs = (CFAbsoluteTimeGetCurrent() - firedAt) * 1000
                let sessionStarted = scrollingSession != nil
                let panelVisible = scrollingPanel?.isVisible ?? false
                let clickThrough = overlays.debugWindowIgnoresMouseEvents(displayID: displayID) ?? false
                try? await Task.sleep(for: .milliseconds(500))
                let previewVisible = scrollingPreview?.isVisible ?? false
                // 首帧要等一次采集，别抢在它前面读。
                var previewWait: Double = 0
                while scrollingSession?.debugPreviewImageSize == nil, previewWait < 3 {
                    try? await Task.sleep(for: .milliseconds(100))
                    previewWait += 0.1
                }
                let previewSize = scrollingSession?.debugPreviewImageSize
                let expectedPreview = ScrollingPreviewPanel.previewPixelSize
                let previewMatches = previewSize.map {
                    abs($0.width - expectedPreview.width) < 1
                        && abs($0.height - expectedPreview.height) < 1
                } ?? false
                report.append(
                    "手动：点「滚动截图 → 手动滚动」→ \(triggered ? "已触发" : "**没触发**")"
                        + "，会话=\(sessionStarted ? "在跑" : "**没起来**")"
                        + "，控制条=\(panelVisible ? "可见" : "**不可见**")"
                        + "，遮罩鼠标穿透=\(clickThrough ? "是（取景框）" : "**否**")"
                        + "，右侧预览=\(previewVisible ? "挂上" : "**没挂**")"
                        + "，预览图=\(previewSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "—")"
                        + "（画布应为 \(Int(expectedPreview.width))×\(Int(expectedPreview.height))）"
                        + "，交出的选区=\(handoff.map { CaptureSelfTest.describe($0.rect) } ?? "—")"
                )
                budgets.append(("预览走小画布（不是整张长图）", previewMatches ? 0 : nil, 0))

                // 抓一张运行中的截图：好亲眼确认预览面板里那张图没有被拉变形
                // （用户报过的就是「刚开始长截图时右侧图片拉伸了」）。
                if let shots = try? await capture.captureAllDisplays(excludingOwnApplication: false),
                    let shot = shots.first(where: { $0.displayID == displayID }) ?? shots.first
                {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("jietu-scroll-preview.png")
                    try? CaptureSelfTest.writePNG(shot.image, to: url)
                    report.append("运行中截图（看右侧预览有没有变形）-> \(url.path)")
                }
                budgets.append(("工具栏触发→会话起来", triggered ? triggerMs : nil, 300))
                budgets.append(("会话在跑", sessionStarted ? 0 : nil, 0))
                budgets.append(("控制条可见", panelVisible ? 0 : nil, 0))
                budgets.append(("遮罩鼠标穿透", clickThrough ? 0 : nil, 0))
                budgets.append(("右侧预览挂上", previewVisible ? 0 : nil, 0))

                cancelScrollingCapture()
                try? await Task.sleep(for: .milliseconds(600))
                report.append(
                    "取消后：会话=\(scrollingSession == nil ? "已收" : "**还在**")"
                        + "，遮罩=\(overlays.isPresenting ? "**还在**" : "已关")"
                )
                budgets.append(("取消后会话收干净", scrollingSession == nil ? 0 : nil, 0))
                budgets.append(("取消后遮罩关掉", overlays.isPresenting ? nil : 0, 0))

                // MARK: 二、自动滚动：光标移出选区 → 暂停 / 移回 → 恢复
                //
                // 用户报的「滚动时鼠标挪不动、点不到完成 / 取消」就是这一步：
                // 合成滚轮以前固定发选区中心，window server 会把光标一起拽过去。
                // 现在滚轮跟着光标走，光标出选区就暂停（顺带把输入让开），按钮随时点得到。
                guard AccessibilityPermission.isGranted else {
                    report.append("自动滚动：跳过（没有辅助功能权限，自动模式跑不起来）")
                    report.append("RESULT: \(budgets.allSatisfy { $0.milliseconds != nil && $0.milliseconds! <= $0.limit } ? "PASS" : "FAIL")")
                    CaptureSelfTest.finish(report, code: 0)
                    return
                }

                guard let autoSelection = await dragSelection() else {
                    report.append("error: 自动滚动这一轮没有形成选区")
                    report.append("RESULT: FAIL")
                    CaptureSelfTest.finish(report, code: 1)
                    return
                }
                let inside = DisplayGeometry.cgPoint(
                    fromLocal: CGPoint(x: autoSelection.midX, y: autoSelection.midY), screen: screen
                )
                let outside = CGPoint(x: inside.x - 80, y: inside.y + autoSelection.height)

                let autoTriggered = overlays.debugTriggerScrollCapture(
                    .automatic, displayID: displayID
                )
                let autoChrome = overlays.debugWindowIgnoresMouseEvents(displayID: displayID) ?? false
                try? await Task.sleep(for: .milliseconds(900))
                let pausedAtStart = scrollingPanel?.debugIsPaused ?? true

                // 自动滚动每拍都会发一次滚轮（事件位置 = 当时的光标），window server 会把光标
                // 同步到那个位置——所以「移出去」这一下可能要试几次，否则会被那一拍顶回来。
                var pauseMs: Double?
                for _ in 0..<8 {
                    let attemptAt = CFAbsoluteTimeGetCurrent()
                    post(.mouseMoved, at: outside)
                    pauseMs = await waitUntil(attemptAt, timeout: 0.6) {
                        scrollingPanel?.debugIsPaused == true
                    }
                    if pauseMs != nil { break }
                }
                try? await Task.sleep(for: .milliseconds(250))
                let cursorNow = DisplayGeometry.flipY(NSEvent.mouseLocation)
                let regionNow = scrollingSession.map { session -> CGRect in
                    // 只用来打印：会话内部的选区矩形与光标是否在外面。
                    session.debugRegion ?? .zero
                } ?? .zero
                report.append(
                    String(
                        format: "（探针）注入后光标 cg=(%.0f,%.0f)，选区 cg=(%.0f,%.0f %.0fx%.0f)，"
                            + "在选区内=%@",
                        cursorNow.x, cursorNow.y, regionNow.minX, regionNow.minY,
                        regionNow.width, regionNow.height,
                        ScrollingCaptureSession.shouldScroll(cursor: cursorNow, region: regionNow)
                            ? "是" : "否"
                    )
                )
                var resumeMs: Double?
                for _ in 0..<8 {
                    let attemptAt = CFAbsoluteTimeGetCurrent()
                    post(.mouseMoved, at: inside)
                    resumeMs = await waitUntil(attemptAt, timeout: 0.6) {
                        scrollingPanel?.debugIsPaused == false
                    }
                    if resumeMs != nil { break }
                }
                let autoTriggerText = autoTriggered ? "已触发" : "**没触发**"
                let autoStartText = pausedAtStart ? "**暂停（不该）**" : "滚动中"
                let autoPauseText = CaptureSelfTest.describe(milliseconds: pauseMs)
                let autoResumeText = CaptureSelfTest.describe(milliseconds: resumeMs)
                let autoChromeText = autoChrome ? "是" : "**否**"
                report.append(
                    "自动：点「滚动截图 → 自动滚动」→ \(autoTriggerText)"
                        + "，一开始=\(autoStartText)"
                        + "，光标移出选区→暂停 \(autoPauseText)"
                        + "，移回→恢复 \(autoResumeText)"
                        + "，取景框=\(autoChromeText)"
                )
                budgets.append(("自动：触发即滚动（不是一上来就暂停）", pausedAtStart ? nil : 0, 0))
                budgets.append(("光标移出选区→暂停", pauseMs, 600))
                budgets.append(("光标移回选区→恢复", resumeMs, 600))

                cancelScrollingCapture()
                try? await Task.sleep(for: .milliseconds(600))

                // MARK: 三、钉图上的「编辑」：点了要回到标注编辑器。
                // 按钮本身 → 回调这条链由 `--selftest-pin` 验；这里验 AppDelegate 接的那一段
                // （收掉钉图、用同一张图开编辑器）。
                if let pinImage = try? CaptureSelfTest.makeTestImage(width: 520, height: 340) {
                    PinWindowController.pin(image: pinImage, on: NSScreen.main)
                    try? await Task.sleep(for: .milliseconds(700))
                    let pinnedVisible = NSApp.windows.contains { $0 is PinPanel && $0.isVisible }
                    PinWindowController.onRequestEdit?(pinImage, .zero)
                    try? await Task.sleep(for: .milliseconds(700))
                    let editorOpened = overlays.isPresenting
                    report.append(
                        "钉图「编辑」→ 原地编辑器：钉图在=\(pinnedVisible ? "是" : "**否**")"
                            + "，原地编辑器=\(editorOpened ? "打开了" : "**没打开**")"
                    )
                    budgets.append(("钉图「编辑」→ 原地编辑器", editorOpened ? 0 : nil, 0))
                    overlays.cancel()
                }

                report.append("延迟预算：")
                var failed = 0
                for budget in budgets {
                    let ok = budget.milliseconds != nil && budget.milliseconds! <= budget.limit
                    if !ok { failed += 1 }
                    report.append(
                        String(
                            format: "    %@ %@ / 预算 %.0f ms  %@",
                            ok ? "✅" : "❌",
                            budget.milliseconds.map { String(format: "%.0f ms", $0) } ?? "**未达成**",
                            budget.limit,
                            budget.label
                        )
                    )
                }
                report.append("RESULT: \(failed == 0 ? "PASS" : "FAIL（\(failed) 项未达成）")")
                CaptureSelfTest.finish(report, code: failed == 0 ? 0 : 1)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                CaptureSelfTest.finish(report, code: 1)
            }
        }
    }

    #endif

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
        menuBar.onOpenHistory = { [weak self] in self?.showHistory() }
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
            self?.openInlineEditor(image)
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
            self?.openInlineEditor(image, anchor: frame)
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
    private func handOffToExistingInstance() -> Bool {
        // 跑单元测试时宿主就是同一个 App bundle，而 App 通常正开着；
        // 这里必须放行，否则测试根本起不来。
        guard !Self.isRunningTests else { return false }
        #if DEBUG
        // app 级自检常与正式实例同时在场（它要真接线，不能当成"多开"被杀掉）。
        for flag in [
            CaptureSelfTest.appLevelInlineScrollFlag, CaptureSelfTest.appLevelRecordingFlag,
            CaptureSelfTest.appLevelRecentMenuFlag,
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

    /// 全屏截图：抓鼠标所在显示器，依设置决定进入原地编辑或交付浮窗。
    private func handleFullScreenCapture() {
        guard !overlays.isPresenting else { return }
        guard requireScreenCapturePermission() else { return }

        Task { @MainActor in
            do {
                let snapshots = try await capture.captureAllDisplays()
                guard let snapshot = snapshotUnderMouse(snapshots) ?? snapshots.first else {
                    throw CaptureError.noDisplays
                }
                switch settings.editorMode {
                case .inline:
                    if settings.playShutterSound {
                        CaptureOutput.playShutterSound()
                    }
                    copyToClipboard(snapshot.image)
                    openInlineEditor(snapshot.image)
                case .window:
                    deliver(snapshot.image, onDisplay: snapshot.displayID)
                }
            } catch {
                presentCaptureFailure(error)
            }
        }
    }

    /// 窗口截图：呈现全屏交互遮罩，支持悬停吸附高亮、空格切换自由框选与一键窗口截取。
    private func handleWindowCapture() {
        overlays.purpose = .windowCapture
        guard !overlays.isPresenting else { return }
        guard requireScreenCapturePermission() else { return }

        Task { @MainActor in
            do {
                let snapshots = try await capture.captureAllDisplays()
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                logger.notice(
                    "window capture initiated: \(snapshots.count) display(s), \(windows.count) window(s)"
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

    /// 定时截图：延时后走区域截图流程。
    private func handleTimedCapture(after seconds: TimeInterval) {
        guard !overlays.isPresenting else { return }
        logger.notice("timed capture scheduled in \(seconds)s")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            handleAreaCapture()
        }
    }

    // MARK: - Screen recording

    /// 录屏的三种取景方式。
    enum RecordingMode {
        /// 拖一块区域（顺手点个窗口也行）。
        case region
        /// 点哪个窗口就录哪个。
        case window
        /// 整块屏（鼠标所在的那块）。
        case fullScreen
    }

    /// 录屏入口：先说清楚录哪块（区域 / 窗口 / 整屏），选区到手后停在「准备录制」。
    ///
    /// - 区域 / 窗口：走既有遮罩取景（两种只差默认的取景手势与光标）；
    /// - 全屏：**不弹遮罩**——鼠标在哪块屏就录哪块，直接上红框 + 控制条的待开始态。
    private func handleScreenRecording(mode: RecordingMode = .region) {
        guard recordingEngine == nil, pendingRecording == nil else {
            logger.notice("recording ignored: already running or waiting to start")
            return
        }
        guard !overlays.isPresenting else {
            logger.notice("recording ignored: overlay is presenting")
            return
        }
        guard requireScreenCapturePermission() else { return }

        if mode == .fullScreen {
            Task { @MainActor in
                do {
                    let snapshots = try await capture.captureAllDisplays()
                    guard let snapshot = snapshotUnderMouse(snapshots) ?? snapshots.first else {
                        throw CaptureError.noDisplays
                    }
                    // 整屏：local 矩形就是这块屏的整幅。
                    beginRecording(
                        snapshot: snapshot,
                        localRect: CGRect(origin: .zero, size: snapshot.screenFrameInPoints.size)
                    )
                } catch {
                    presentCaptureFailure(error)
                }
            }
            return
        }

        Task { @MainActor in
            do {
                let snapshots = try await capture.captureAllDisplays()
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                overlays.purpose = (mode == .window) ? .recordWindow : .record
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

    /// 选区到手：收掉遮罩 → 上红框与控制条 → 开录。
    /// 选区到手：收掉遮罩 → 上红框与控制条，**停在「准备录制」**等用户点「开始」。
    ///
    /// 不自动开录：录屏是「先把框摆好再决定」，自动开录会把用户还没准备好的那几秒也录进去
    /// （滚动长图那边也是同一套路：控制条先停在待开始态）。
    private func beginRecording(snapshot: DisplaySnapshot, localRect: CGRect) {
        guard recordingEngine == nil, pendingRecording == nil else { return }
        guard let target = makeRegionTarget(snapshot: snapshot, localRect: localRect) else {
            overlays.cancel()
            return
        }
        // 遮罩用完即收：接着是红框 + 控制条，两者都会被录制排除。
        overlays.cancel()

        let screen = NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID }
            ?? NSScreen.main
        let border = RecordingBorderPanel()
        border.present(around: target.selectionRect)
        let hud = RecordingControlPanel()
        hud.present(near: target.selectionRect, in: screen, phase: .ready)
        recordingBorder = border
        recordingHUD = hud
        pendingRecording = (displayID: snapshot.displayID, region: target.region)

        hud.onStart = { [weak self] in self?.startRecording() }
        hud.onTogglePause = { [weak self] in self?.toggleRecordingPause() }
        hud.onStop = { [weak self] in self?.stopRecording() }
        hud.onCancel = { [weak self] in self?.cancelRecording() }
        recordingElapsed = 0
        recordingDisplayID = snapshot.displayID
        registerRecordingKeyMonitors()
    }

    /// 用户点了「开始」（待开始态按 ⌘⇧S 同样走这里）：**这才真的开录**。
    private func startRecording() {
        guard let pending = pendingRecording, recordingEngine == nil else { return }
        pendingRecording = nil
        recordingHUD?.setPhase(.recording)
        recordingElapsed = 0

        let engine = RecordingEngine()
        engine.onTick = { [weak self, weak hud = recordingHUD] elapsed in
            hud?.update(elapsed: elapsed)
            self?.recordingElapsed = elapsed
        }
        engine.onFinish = { [weak self] url in self?.finishRecording(temporaryURL: url) }
        engine.onFail = { [weak self] error in self?.failRecording(error) }
        recordingEngine = engine

        let options = RecordingEngine.Options(
            fps: settings.recordFrameRate,
            capturesSystemAudio: settings.recordSystemAudio
        )
        let excluded = [recordingHUD?.windowNumber, recordingBorder?.windowNumber].compactMap { $0 }
        Task { @MainActor in
            do {
                try await engine.start(
                    displayID: pending.displayID,
                    regionInPoints: pending.region,
                    options: options,
                    excludingWindowNumbers: excluded
                )
            } catch {
                failRecording(error)
            }
        }
    }

    /// 「完成」：收工保存。
    private func stopRecording() {
        guard let engine = recordingEngine else { return }
        Task { await engine.stop() }
    }

    /// 暂停 / 继续。
    private func toggleRecordingPause() {
        guard let engine = recordingEngine else { return }
        if engine.isPaused {
            engine.resume()
            recordingHUD?.setPaused(false)
        } else {
            engine.pause()
            recordingHUD?.setPaused(true)
        }
    }

    /// 取消：不保存。
    private func cancelRecording() {
        // 待开始那一档还没有引擎（也就没有文件要丢）：直接收掉红框 + 控制条。
        if let engine = recordingEngine {
            Task { await engine.cancel() }
        }
        stopRecordingUI()
    }

    /// 录屏收工：把临时 mp4 搬进保存目录（命名模板 + 同名序号），
    /// 再给一张**浮窗视频卡**（看得见、拿得走）+ 一条通知。
    private func finishRecording(temporaryURL: URL) {
        let elapsed = recordingElapsed
        let displayID = recordingDisplayID ?? NSScreen.main?.jietu_displayID
        stopRecordingUI()
        do {
            let url = try CaptureOutput.moveFile(
                temporaryURL,
                toDirectory: settings.saveDirectory,
                nameTemplate: settings.effectiveFilenameTemplate,
                fileExtension: "mp4"
            )
            logger.notice("recording saved: \(url.lastPathComponent)")
            if settings.showSaveNotification {
                notifier.notifyRecordingSaved(fileURL: url, duration: elapsed)
            }
            Task { @MainActor [weak self] in
                await self?.presentRecordingCard(
                    url: url, elapsed: elapsed, displayID: displayID
                )
            }
        } catch {
            presentRecordingFailure(error)
        }
    }

    /// 收工后的浮窗视频卡：从成片里取一帧当封面 + 读真实时长。
    ///
    /// 封面取不出来（编码没写完整 / 文件被挪走）就只留通知——收工流程不该被一张封面卡住。
    private func presentRecordingCard(
        url: URL,
        elapsed: TimeInterval,
        displayID: CGDirectDisplayID?
    ) async {
        guard let card = await VideoThumbnail.make(for: url) else {
            logger.notice("recording card skipped: no thumbnail for \(url.lastPathComponent)")
            return
        }
        let screen = NSScreen.screens.first { $0.jietu_displayID == displayID } ?? NSScreen.main
        let backingScale = max(1, screen?.backingScaleFactor ?? 2)
        // 封面是按**像素**解出来的（解码时已收到 520 以内），换成点才是它在屏幕上该占多大。
        let pointSize = CGSize(
            width: CGFloat(card.image.width) / backingScale,
            height: CGFloat(card.image.height) / backingScale
        )
        quickAccess.presentVideo(
            url: url,
            thumbnail: card.image,
            thumbnailPointSize: pointSize,
            duration: card.duration > 0 ? card.duration : elapsed,
            onDisplay: displayID ?? screen?.jietu_displayID ?? CGMainDisplayID()
        )
    }

    private func failRecording(_ error: Error) {
        logger.error("recording failed: \(error.localizedDescription)")
        stopRecordingUI()
        presentRecordingFailure(error)
    }

    private func presentRecordingFailure(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "录屏没能完成"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 收掉控制条 / 红框 / 按键监视器（会话本身由引擎自己收尾）。
    private func stopRecordingUI() {
        for monitor in recordingKeyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        recordingKeyMonitors.removeAll()
        recordingHUD?.close()
        recordingHUD = nil
        recordingBorder?.close()
        recordingBorder = nil
        recordingEngine = nil
        pendingRecording = nil
    }

    /// Esc = 取消（不保存）；⌘⇧P 暂停 / 继续；⌘⇧S 完成（待开始态则是「开始」）。
    ///
    /// 本地 + 全局都装：录屏时用户多半在操作别的 App，只有本地监视器收不到按键。
    /// 全局监视器只能旁观、拦不住事件（系统限制），所以两边都挂。
    private func registerRecordingKeyMonitors() {
        for monitor in recordingKeyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        recordingKeyMonitors.removeAll()

        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 {
                self.cancelRecording()
                return nil
            }
            if flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() {
                if key == "p" {
                    self.toggleRecordingPause()
                    return nil
                }
                if key == "s" {
                    // 待开始态按 ⌘⇧S = 开始录制；录制中 = 完成。
                    if self.recordingEngine != nil {
                        self.stopRecording()
                    } else {
                        self.startRecording()
                    }
                    return nil
                }
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancelRecording() }
        }
        recordingKeyMonitors = [local, global].compactMap { $0 }
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
    /// 一块区域的三套坐标（滚动长图与录屏共用）。
struct CaptureRegionTarget {
        let snapshot: DisplaySnapshot
        /// SCK 的 `sourceRect`（本显示器内、原点左上）。
        let region: CGRect
        /// 全局 cg 坐标（自动滚动的合成滚轮事件发到这里）。
        let globalRect: CGRect
        /// 选区在 AppKit 全局坐标里的矩形（控制条与预览都贴它定位）。
        let selectionRect: CGRect
    }

    /// 把「本显示器 local 矩形」换算成三套坐标（SCK 的 sourceRect / 全局 cg / 面板摆放用的 AppKit 全局）。
    ///
    /// 滚动长图与录屏都用它：前者反复采样同一块，后者开一条采集流。
    private func makeRegionTarget(
        snapshot: DisplaySnapshot,
        localRect: CGRect
    ) -> CaptureRegionTarget? {
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
        // 必须用 `cgRect`（整块矩形换算）：local 的 origin 是左下角，翻到 cg 是上边，
        // 直接拿它配 size 会把选区整体往下推一个高度——滚轮发到别处、输入屏蔽区也会盖住控制条。
        let screen = NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID }
        let globalRect = screen.map {
            DisplayGeometry.cgRect(fromLocal: localRect, screen: $0)
        } ?? localRect

        let selectionRect = CGRect(
            x: screenFrame.minX + localRect.minX,
            y: screenFrame.minY + localRect.minY,
            width: localRect.width,
            height: localRect.height
        )
        return CaptureRegionTarget(
            snapshot: snapshot,
            region: region,
            globalRect: globalRect,
            selectionRect: selectionRect
        )
    }

    /// 就地编辑工具栏里选了「手动 / 自动滚动」：**用当前选区直接开跑**。
    ///
    /// 与 `presentScrollingModeBar` 的区别只有一条：模式条那一步省掉了——
    /// 用户在下拉里已经回答过「谁来滚」，再问一遍就是多一步。
    private func startScrollingCaptureFromInline(
        snapshot: DisplaySnapshot,
        mode: ScrollingCaptureSession.Mode,
        localRect: CGRect
    ) {
        guard scrollingSession == nil else { return }
        guard let target = makeRegionTarget(snapshot: snapshot, localRect: localRect) else {
            return
        }
        // 上一次可能还留着一条模式条（用户没点开始也没取消）：先收干净。
        if scrollingPanel != nil { dismissScrollingPanel() }
        scrollingTarget = target
        isScrollingCancelled = false

        let panel = ScrollingCapturePanelController()
        scrollingPanel = panel
        panel.onStartManual = { [weak self] in self?.beginScrollingSession(mode: .manual) }
        panel.onStartAuto = { [weak self] in self?.beginScrollingSession(mode: .automatic) }
        panel.onFinish = { [weak self] in self?.scrollingSession?.stop() }
        panel.onCancel = { [weak self] in self?.cancelScrollingCapture() }
        // 直接从「进行中」起：模式已经选过了，不要再闪一下「手动 / 自动」那条。
        panel.present(near: target.selectionRect, stage: .running(mode))
        registerScrollingEscapeMonitor()
        beginScrollingSession(mode: mode)
    }

    /// 鼠标在选区上停住（或松手）：把紧凑的「手动 / 自动」条浮到选框下方。
    private func presentScrollingModeBar(snapshot: DisplaySnapshot, localRect: CGRect) {
        guard overlays.purpose == .regionPick, scrollingSession == nil else { return }
        guard let target = makeRegionTarget(snapshot: snapshot, localRect: localRect) else {
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
            let target = makeRegionTarget(snapshot: snapshot, localRect: localRect)
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
        session.onPausedChange = { [weak panel] paused in
            panel?.setPaused(paused)
        }
        // 预览画布按面板像素尺寸定比例、只增量画新内容：长图再长也不会卡。
        session.previewPixelSize = ScrollingPreviewPanel.previewPixelSize

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
        case .windowCaptured(let window, let snapshot):
            handleWindowCaptured(window: window, snapshot: snapshot)
        }
    }

    /// 窗口截图完成：优先独立截取纯净窗口（无视遮挡），应用原生圆角与 macOS 拟物多层柔和阴影，最后交付。
    private func handleWindowCaptured(window: WindowInfo, snapshot: DisplaySnapshot) {
        Task { @MainActor in
            do {
                // 1. 优先使用 SCContentFilter 独立捕获纯净窗口内容（无视任何遮挡）
                let rawImage = try await capture.captureWindow(window)
                let finalImage = WindowEffects.applyWindowEffects(
                    to: rawImage,
                    shadowEnabled: settings.windowShadowEnabled,
                    shadowSize: settings.windowShadowSize,
                    scale: snapshot.effectiveScale
                )
                deliver(finalImage, onDisplay: snapshot.displayID)
            } catch {
                logger.warning(
                    "independent window capture failed: \(error.localizedDescription), falling back to screen crop"
                )
                // 2. 若独立捕获不可用（如特殊系统浮层），回退到底图截取并套用圆角与阴影
                let screen = NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID } ?? NSScreen.main!
                let localRect = DisplayGeometry.localRect(
                    fromCGRect: window.frameInCGPoints,
                    screen: screen
                ).intersection(CGRect(origin: .zero, size: screen.frame.size))
                if let cropped = CaptureOutput.crop(snapshot, toLocalRect: localRect) {
                    let finalImage = WindowEffects.applyWindowEffects(
                        to: cropped,
                        shadowEnabled: settings.windowShadowEnabled,
                        shadowSize: settings.windowShadowSize,
                        scale: snapshot.effectiveScale
                    )
                    deliver(finalImage, onDisplay: snapshot.displayID)
                } else {
                    presentCaptureFailure(error)
                }
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
            openInlineEditor(image, anchor: screenRect)
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

    /// 从浮窗（钉图或快速访问）恢复到原地编辑模式：图片在屏幕中央居中展示，下方出现工具栏。
    private func openInlineEditor(_ image: CGImage, anchor: CGRect? = nil) {
        guard !overlays.isPresenting else { return }
        guard requireScreenCapturePermission() else { return }

        // 确定目标屏幕：优先包含 anchor 的屏幕，否则主屏幕
        let targetScreen: NSScreen
        if let anchor, anchor.width > 0, anchor.height > 0 {
            targetScreen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens.first!
        } else {
            targetScreen = NSScreen.main ?? NSScreen.screens.first!
        }

        Task { @MainActor in
            do {
                let snapshots = try await capture.captureAllDisplays()
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                let session = CaptureSession(snapshots: snapshots, windows: windows)
                overlays.present(
                    session: session,
                    inlineMode: true,
                    restoredImage: image,
                    targetScreen: targetScreen
                )
            } catch {
                logger.error("failed to open inline editor: \(error.localizedDescription)")
                presentCaptureFailure(error)
            }
        }
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
    @discardableResult
    private func saveAs(_ image: CGImage, ensuresHistory: Bool = false) -> Bool {
        let panel = NSSavePanel()
        panel.directoryURL = settings.saveDirectory
        panel.canCreateDirectories = true
        panel.allowedContentTypes = settings.saveFormat == .png ? [.png] : [.jpeg]
        let base = FilenameTemplate.makeName(
            template: settings.effectiveFilenameTemplate,
            date: Date()
        )
        panel.nameFieldStringValue = "\(base).\(settings.saveFormat.fileExtension)"

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let data: Data?
            switch settings.saveFormat {
            case .png: data = CaptureOutput.pngData(image)
            case .jpeg: data = CaptureOutput.jpegData(image, quality: settings.jpegQuality)
            }
            guard let data else { throw CaptureOutputError.encodingFailed }
            try data.write(to: url, options: .atomic)
            if ensuresHistory {
                recordHistory(image)
            }
            didSave(to: url)
            return true
        } catch {
            logger.error("save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 视频卡的「保存」：把成片**另存一份**到用户挑的地方。
    ///
    /// 与截图的「保存」同一个面板、同一个默认目录；差别是原片已经在保存目录里了，
    /// 所以这是**复制**（原片留着，卡片上的播放 / 在访达中显示 / 拖拽都还指着它）。
    private func saveVideoAs(_ url: URL) {
        let panel = NSSavePanel()
        panel.directoryURL = settings.saveDirectory
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // 选到原片自己：什么都不做（绝不允许「先删目标再拷」把自己删了）。
        guard destination.standardizedFileURL != url.standardizedFileURL else { return }
        do {
            // 面板已经确认过「替换」，这里先清掉同名文件再拷。
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            logger.notice("recording saved as: \(destination.lastPathComponent)")
        } catch {
            logger.error("save recording as failed: \(error.localizedDescription)")
        }
    }

    /// 落盘后的统一收尾：记入最近截图 + 图标闪烁 + 通知。
    private func didSave(to url: URL) {
        // 历史那条记上「用户的文件在哪」：打开 / 在访达中显示都该落到它上面。
        HistoryStore.shared.attachSavedFile(url, to: HistoryStore.shared.latestID)
        settings.recordCapture(url)
        logger.notice("saved capture to \(url.path, privacy: .public)")
        if settings.showSaveNotification {
            notifier.notifySaved(fileURL: url)
        }
    }

    /// 打开历史某一项进入标注（居中原地编辑）。
    private func openHistoryItem(_ item: HistoryItem) {
        if let cgImage = item.cgImage {
            openInlineEditor(cgImage)
            return
        }
        guard let url = item.url,
            let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        openInlineEditor(cgImage)
    }

    /// 清空所有历史与最近记录。
    private func clearAllHistory() {
        settings.clearRecentCaptures()
        HistoryStore.shared.removeAll()
        HistoryThumbnailCache.shared.clear()
    }

    /// 托盘历史面板（保留兼容）。
    private func showHistory() {
        if historyPanel == nil {
            let controller = HistoryPanelController()
            controller.itemsProvider = { [weak self] in self?.historyItems() ?? [] }
            controller.onSelect = { [weak self] item in
                self?.openHistoryItem(item)
            }
            historyPanel = controller
        }
        historyPanel?.toggle()
    }

    /// 会话内截图（最新在前）+ 磁盘上保存过的截图，按时间倒序且按路径去重。
    private func historyItems() -> [HistoryItem] {
        var seenURLs = Set<URL>()
        var result: [HistoryItem] = []

        // 落盘历史：唯一的那份（重启后全靠它）。
        for entry in HistoryStore.shared.entries {
            let url = entry.displayURL
            guard !seenURLs.contains(url) else { continue }
            seenURLs.insert(url)
            result.append(
                HistoryItem(
                    id: entry.id,
                    date: entry.date,
                    image: HistoryThumbnailCache.shared.image(for: url),
                    url: url,
                    cgImage: nil
                )
            )
        }

        // 更早的「保存到磁盘」留下的文件（这个功能之前就用它列）：还认得出来的也列上。
        for url in settings.recentCaptureURLs {
            guard !seenURLs.contains(url) else { continue }
            seenURLs.insert(url)
            result.append(
                HistoryItem(
                    id: url.path,
                    date: FilenameTemplate.captureDate(of: url),
                    image: HistoryThumbnailCache.shared.image(for: url),
                    url: url,
                    cgImage: nil
                )
            )
        }

        return result
            .sorted { $0.date > $1.date }
            .prefix(40)
            .map { $0 }
    }

    /// 记录一次截图到「最近截图」历史。
    ///
    /// **只有这一份**（`HistoryStore`）：以前这里还另存一份内存里的会话历史，于是同一次截图
    /// 会在菜单里出现两次（未保存的那份没有 url，按 url 去重根本抓不住它）。
    private func recordHistory(_ image: CGImage) {
        HistoryStore.shared.record(image)
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
