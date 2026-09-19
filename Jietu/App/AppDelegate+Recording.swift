import AppKit
import os

/// AppDelegate — 录屏流程（选区、HUD、红框、暂停、落盘、失败处理）。
///
/// @author ixxxxoooo
extension AppDelegate {

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
    func handleScreenRecording(mode: RecordingMode = .region) {
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
    func beginRecording(snapshot: DisplaySnapshot, localRect: CGRect) {
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
        // 待开始态就亮明麦克风：设置里开着显示「会录」，关着显示「不录」——
        // 别让用户录完才发现没声音。
        hud.setMicrophone(settings.recordMicrophone ? .active : .off)
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
    func startRecording() {
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

        let excluded = [recordingHUD?.windowNumber, recordingBorder?.windowNumber].compactMap { $0 }
        Task { @MainActor in
            do {
                // 麦克风开着的：开录前先过权限。拒绝 / 不是 Determinate 的弹一次系统授权，
                // 用户不给就当这次没开——录屏本身不该被声音挡住。
                var wantsMicrophone = false
                if settings.recordMicrophone {
                    wantsMicrophone = await MicrophoneCapture.requestPermission()
                }
                let options = RecordingEngine.Options(
                    fps: settings.recordFrameRate,
                    capturesSystemAudio: settings.recordSystemAudio,
                    capturesMicrophone: wantsMicrophone
                )
                try await engine.start(
                    displayID: pending.displayID,
                    regionInPoints: pending.region,
                    options: options,
                    excludingWindowNumbers: excluded
                )
                // 开关开着却没启用麦克风（未授权 / 没设备）：说出来，别让用户录完才发现没声音。
                if settings.recordMicrophone {
                    if engine.isMicrophoneActive {
                        recordingHUD?.setMicrophone(.active)
                    } else {
                        recordingHUD?.setMicrophone(.unavailable)
                        logger.notice("microphone was requested but not active; system audio only")
                        notifier.notifyMicrophoneUnavailable()
                    }
                } else {
                    recordingHUD?.setMicrophone(.off)
                }
            } catch {
                failRecording(error)
            }
        }
    }

    /// 「完成」：收工保存。
    func stopRecording() {
        guard let engine = recordingEngine else { return }
        Task { await engine.stop() }
    }

    /// 暂停 / 继续。
    func toggleRecordingPause() {
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
    func cancelRecording() {
        // 待开始那一档还没有引擎（也就没有文件要丢）：直接收掉红框 + 控制条。
        if let engine = recordingEngine {
            Task { await engine.cancel() }
        }
        stopRecordingUI()
    }

    /// 录屏收工：把临时 mp4 搬进保存目录（命名模板 + 同名序号），
    /// 再给一张**浮窗视频卡**（看得见、拿得走）+ 一条通知。
    func finishRecording(temporaryURL: URL) {
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
    func presentRecordingCard(
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

    func failRecording(_ error: Error) {
        logger.error("recording failed: \(error.localizedDescription)")
        stopRecordingUI()
        presentRecordingFailure(error)
    }

    func presentRecordingFailure(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "录屏没能完成"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 收掉控制条 / 红框 / 按键监视器（会话本身由引擎自己收尾）。
    func stopRecordingUI() {
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
    func registerRecordingKeyMonitors() {
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
}
