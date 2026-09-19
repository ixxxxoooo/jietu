import AppKit
import AVFoundation
import os

#if DEBUG
/// AppDelegate — 应用级 DEBUG 自检（仅 Debug 构建编译）。
///
/// @author ixxxxoooo
extension AppDelegate {
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
    func runRecentMenuAppTest() {
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
    func popAndShootRecentMenu(_ menu: NSMenu, name: String) {
        recentMenuUnderTest = menu
        recentMenuShotName = name
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishRecentMenuShot() }
        }
        RunLoop.current.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: CGPoint(x: 420, y: 420), in: nil)
    }

    func finishRecentMenuShot() {
        shootRecentMenu(recentMenuShotName ?? "menu")
        recentMenuUnderTest?.cancelTracking()
        recentMenuUnderTest = nil
    }

    func shootRecentMenu(_ name: String) {
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
    func runRecordingAppTest() {
        Task { @MainActor in
            var report: [String] = []
            var budgets: [(label: String, milliseconds: Double?, limit: Double)] = []
            let savedDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("jietu-record-apptest-\(UUID().uuidString)", isDirectory: true)
            // **改过的设置一律还回去**：`saveDirectory` 是落 UserDefaults 的，
            // 自检把目录指到临时目录又不还原的话，用户的截图会一直往一个（跑完就被删掉的）
            // 临时目录里存——「最近截图」永远是空的，正是这么来的。
            //
            // 注意**不能用 defer**：自检收尾走的是 `CaptureSelfTest.finish` → `exit()`，
            // 而 `exit()` 不执行 defer（实测跑完一次自检，用户的保存目录就永久留在临时目录里）。
            // 注册到 `cleanupBeforeExit`，由 `finish` 在退出前统一执行。
            let previousSaveDirectory = settings.saveDirectory
            let previousShowSaveNotification = settings.showSaveNotification
            CaptureSelfTest.cleanupBeforeExit.append { [weak self] in
                self?.settings.saveDirectory = previousSaveDirectory
                self?.settings.showSaveNotification = previousShowSaveNotification
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

                // 控制条**不能压在选区上**：它虽然被排除在成片之外，但压在选区里会挡住
                // 用户盯着看的内容（用户报的「开始录屏之后有点遮挡」）。
                if let hudFrame = recordingHUD?.panelFrame, let selection = recordingSelectionRect {
                    let overlaps = hudFrame.intersects(selection)
                    let outside = hudFrame.minY >= selection.maxY
                        || hudFrame.maxY <= selection.minY
                        || hudFrame.maxX <= selection.minX
                        || hudFrame.minX >= selection.maxX
                    report.append(
                        "控制条 \(CaptureSelfTest.rectText(hudFrame)) vs 选区 "
                            + "\(CaptureSelfTest.rectText(selection))："
                            + "重叠=\(overlaps ? "**是**" : "否")，在选区外=\(outside ? "是" : "**否**")"
                    )
                    budgets.append(("控制条不遮挡选区", overlaps ? nil : 0, 0))
                }
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

    func runInlineScrollAppTest() {
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

    /// 裁剪窗口：真接线打开它，一步一步打印到 stdout。
    ///
    /// 为什么不用最后汇总报告：这条自检就是来查**崩溃**的——真崩了 `finish` 根本不会执行，
    /// 只有「每步立刻 print + flush」才能看到最后走到哪儿（那一行就是现场）。
    func runTrimAppTest() {
        setvbuf(stdout, nil, _IONBF, 0)
        func step(_ text: String) {
            print("[trim] \(text)")
            fflush(stdout)
        }
        step("开始（进程 \(ProcessInfo.processInfo.processIdentifier)）")
        Task { @MainActor in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("jietu-trim-apptest-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                let source = directory.appendingPathComponent("source.mp4")
                step("造 2 秒测试视频…")
                _ = try await VideoToolsSelfTest.makeTestVideo(
                    at: source, seconds: 2, fps: 30, size: CGSize(width: 320, height: 240)
                )
                step("源视频就绪：\(source.path)")

                step("调 openVideoTrim…")
                openVideoTrim(source)
                step("openVideoTrim 返回，controller=\(videoTrimController == nil ? "无" : "有")")

                try? await Task.sleep(for: .seconds(2))
                let windows = NSApp.windows.filter { $0.title == "裁剪视频" }
                step(
                    "2 秒后：进程存活 ✓，裁剪窗口 \(windows.count) 个，"
                        + "可见=\(windows.contains { $0.isVisible } ? "是" : "否")"
                )

                step("关掉窗口")
                videoTrimController?.close()
                try? await Task.sleep(for: .milliseconds(600))
                step("窗口关闭后 controller=\(videoTrimController == nil ? "已清" : "**没清**")")
                try? FileManager.default.removeItem(at: directory)
                step("RESULT: PASS（全程没崩）")
                CaptureSelfTest.finish(["RESULT: PASS（全程没崩，窗口能开能关）"], code: 0)
            } catch {
                step("error: \(error.localizedDescription)")
                CaptureSelfTest.finish(["RESULT: FAIL"], code: 1)
            }
        }
    }

}
#endif
