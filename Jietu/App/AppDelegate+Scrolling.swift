import AppKit
import os

/// AppDelegate — 滚动长图流程（选区、会话、预览、完成）。
///
/// @author ixxxxoooo
extension AppDelegate {

    /// 滚动长图：先用遮罩取一块选区；鼠标一停住就把「手动 / 自动」浮到选框下方，
    /// 用户点哪一个才开跑。
    func handleScrollingCapture() {
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
    func resolveScrollingMode(
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
    func makeRegionTarget(
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
    func startScrollingCaptureFromInline(
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

        let panel = makeScrollingPanel()
        // 直接从「进行中」起：模式已经选过了，不要再闪一下「手动 / 自动」那条。
        panel.present(near: target.selectionRect, stage: .running(mode))
        registerScrollingEscapeMonitor()
        beginScrollingSession(mode: mode)
    }

    /// 鼠标在选区上停住（或松手）：把紧凑的「手动 / 自动」条浮到选框下方。
    func presentScrollingModeBar(snapshot: DisplaySnapshot, localRect: CGRect) {
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

        let panel = makeScrollingPanel()
        panel.present(near: target.selectionRect)
        registerScrollingEscapeMonitor()
    }

    /// 创建并接线滚动长图控制条（统一创建入口，避免重复接线）。
    @discardableResult
    func makeScrollingPanel() -> ScrollingCapturePanelController {
        let panel = ScrollingCapturePanelController()
        scrollingPanel = panel
        isScrollingCancelled = false
        panel.onStartManual = { [weak self] in self?.beginScrollingSession(mode: .manual) }
        panel.onStartAuto = { [weak self] in self?.beginScrollingSession(mode: .automatic) }
        panel.onFinish = { [weak self] in self?.scrollingSession?.stop() }
        panel.onCancel = { [weak self] in self?.cancelScrollingCapture() }
        return panel
    }

    /// 选区被拖动 / 缩放 / 清空：模式条一路贴着选框走；选区没了就把它收掉。
    func updateScrollingSelection(snapshot: DisplaySnapshot, localRect: CGRect?) {
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
    func dismissScrollingPanel() {
        removeScrollingEscapeMonitor()
        scrollingPanel?.close()
        scrollingPanel = nil
        scrollingTarget = nil
    }

    // MARK: - Scrolling capture: session

    /// 用户点了「手动 / 自动」：这时候才把遮罩切成取景框，然后开跑。
    func beginScrollingSession(mode: ScrollingCaptureSession.Mode) {
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
    func cancelScrollingCapture() {
        isScrollingCancelled = true
        if let session = scrollingSession {
            session.stop()
        } else {
            finishScrollingCapture(image: nil, displayID: CGMainDisplayID())
        }
    }

    /// Esc 结束采样（控制条未必拿得到焦点，这里再兜一层）。
    func registerScrollingEscapeMonitor() {
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

    func removeScrollingEscapeMonitor() {
        if let scrollingEscapeMonitor {
            NSEvent.removeMonitor(scrollingEscapeMonitor)
        }
        scrollingEscapeMonitor = nil
    }

    func finishScrollingCapture(image: CGImage?, displayID: CGDirectDisplayID) {
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

    func snapshotUnderMouse(_ snapshots: [DisplaySnapshot]) -> DisplaySnapshot? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
            let id = screen.jietu_displayID
        else { return nil }
        return snapshots.first { $0.displayID == id }
    }

    func displayID(containing window: WindowInfo) -> CGDirectDisplayID {
        let center = CGPoint(
            x: window.frameInCGPoints.midX,
            y: DisplayGeometry.referenceHeight - window.frameInCGPoints.midY
        )
        return NSScreen.screens.first { $0.frame.contains(center) }?.jietu_displayID
            ?? NSScreen.main?.jietu_displayID
            ?? 0
    }
}
