import AVFoundation
import AppKit
import os
@preconcurrency import ScreenCaptureKit

/// 录屏会话：`SCStream` 逐帧 → `AVAssetWriter` 写成 mp4。
///
/// 参考 capcap 的 `RecordingEngine`（它也是逐帧 + AVAssetWriter，没用 macOS 15 的
/// `SCRecordingOutput`——逐帧那条路可控性更好：能丢帧、能暂停、能自己记时间轴）：
/// - **区域**录制 = 显示器 filter + `config.sourceRect`（不是窗口 filter）；
/// - HUD / 红框这些自家 chrome 通过 `excludingWindows` 排除，**不排除整个 App**——
///   用户可能就是想把钉图浮窗录进去；
/// - 写帧与时间轴记账全在一条串行队列上，主线程只发指令；
/// - 暂停 = 丢帧 + 把后续 PTS 整体前移，暂停那段不出现在成片里、也不留空档。
///
/// **音频双轨**（参考 capcap）：
/// - 系统声音走 SCStream `.audio` → `systemAudioInput` 轨；
/// - 麦克风走独立的 `MicrophoneRecorder`（AVAudioEngine）→ `microphoneInput` 轨；
/// - 两轨独立写入 mp4，播放器同时播放；不做手动 PCM 混音。
///
/// @author ygw
@MainActor
final class RecordingEngine {
    struct Options {
        /// 帧率（`minimumFrameInterval` = 1/fps）。
        var fps: Int = 30
        /// 录系统声音（页面里的视频、音乐）。
        var capturesSystemAudio = false
        /// 录麦克风（权限由调用方先申请；没设备 / 起不来会自动降级成无麦克风）。
        var capturesMicrophone = false
        /// 指定麦克风的 CoreAudio UID（nil = 系统默认输入）。
        var microphoneDeviceUID: String?
        var showsCursor = true
    }

    /// 失败原因。标 `nonisolated`：写盘那条链跑在后台队列上，
    /// 而本模块默认 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不标就跨不过去。
    nonisolated enum Failure: LocalizedError {
        case permissionDenied
        case displayNotShareable(CGDirectDisplayID)
        case emptyRegion
        case startFailed(String)
        case stream(Error)
        case writer(Error)
        /// 一帧都没写进去：选区是全黑的 / 采集被系统掐了。
        case noFrames

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "没有「屏幕录制」权限，录不了屏。"
            case .displayNotShareable(let id): return "拿不到显示器 \(id) 的可共享内容。"
            case .emptyRegion: return "选区太小了，先拖一块像样的区域。"
            case .startFailed(let reason): return "开始录制失败：\(reason)"
            case .stream(let error): return "采集流中断：\(error.localizedDescription)"
            case .writer(let error): return "写视频失败：\(error.localizedDescription)"
            case .noFrames: return "一帧都没录到，选区里可能没有画面变化。"
            }
        }
    }

    /// 每秒一次报「已录多少秒」（暂停的时间不计）。
    var onTick: ((TimeInterval) -> Void)?
    /// 正常收工：参数是**临时文件**路径（由调用方搬到保存目录）。
    var onFinish: ((URL) -> Void)?
    var onFail: ((Error) -> Void)?

    private let logger = Logger(subsystem: "com.ixxxxoooo.jietu", category: "recording")
    /// 写帧与时间轴都在它上面（回调也投到它上面），主线程只发指令。
    private let queue = DispatchQueue(label: "com.ixxxxoooo.jietu.recording")

    private var stream: SCStream?
    private var output: RecordingStreamOutput?
    private var writer: RecordingWriter?
    private var microphoneRecorder: MicrophoneRecorder?
    private var ticker: Timer?

    private(set) var isRunning = false
    private(set) var isPaused = false
    /// 这次录制麦克风**真的**启用了没。
    ///
    /// 调用方拿它做用户可见的反馈：开关开着却没启用（多半是没授权）必须说出来，
    /// 否则用户录完才发现没声音。
    private(set) var isMicrophoneActive = false
    private var startedAt: Date?

    // MARK: - 生命周期

    func start(
        displayID: CGDirectDisplayID,
        regionInPoints: CGRect,
        options: Options = Options(),
        excludingWindowNumbers: [Int] = []
    ) async throws {
        guard !isRunning else { return }
        guard ScreenCapturePermission.isGranted else { throw Failure.permissionDenied }

        let region = regionInPoints.integral
        guard region.width >= 4, region.height >= 4 else { throw Failure.emptyRegion }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            throw Failure.startFailed(error.localizedDescription)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.displayNotShareable(displayID)
        }

        let fps = max(1, min(60, options.fps))
        let scale = NSScreen.screens.first { $0.jietu_displayID == displayID }?
            .backingScaleFactor ?? 2
        let dimensions = VideoEncodingSettings.evenDimensions(
            width: Int((region.width * scale).rounded()),
            height: Int((region.height * scale).rounded())
        )

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        configuration.showsCursor = options.showsCursor
        // 系统声走 SCStream `.audio`；麦克风不走 SCK——走独立的 MicrophoneRecorder。
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.sampleRate = 44_100
        configuration.channelCount = 2

        // 只排除自家的控制条 / 红框，别的 Jietu 窗口（比如钉图）照常入镜。
        let excluded = content.windows.filter {
            excludingWindowNumbers.contains(Int($0.windowID))
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let url = Self.makeTemporaryURL()
        let writer = try RecordingWriter(
            url: url,
            width: dimensions.width,
            height: dimensions.height,
            fps: fps,
            withSystemAudio: options.capturesSystemAudio,
            withMicrophone: options.capturesMicrophone
        )
        let output = RecordingStreamOutput()
        output.onScreenFrame = { [writer] pixelBuffer, time in
            writer.append(pixelBuffer: pixelBuffer, at: time)
        }
        output.onSystemAudio = { [writer] sampleBuffer in
            writer.appendSystemAudio(sampleBuffer)
        }
        output.onStopped = { [weak self] error in
            Task { @MainActor in self?.handleStreamStopped(error) }
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            if options.capturesSystemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            }
            try await stream.startCapture()
        } catch {
            writer.cancel()
            throw Failure.startFailed(error.localizedDescription)
        }

        self.writer = writer
        self.output = output
        self.stream = stream
        isRunning = true
        isPaused = false
        startedAt = Date()

        // 麦克风走 AVAudioEngine 独立采集（参考 capcap）
        if options.capturesMicrophone {
            startMicrophoneRecording(deviceUID: options.microphoneDeviceUID)
        }

        startTicker()
        logger.notice(
            "recording \(dimensions.width)x\(dimensions.height)@\(fps) audio=\(options.capturesSystemAudio) mic=\(options.capturesMicrophone) micDevice=\(options.microphoneDeviceUID ?? "default")"
        )
    }

    // MARK: - 麦克风

    /// 启动麦克风录制。失败则降级——录屏不会因为声音而取消。
    private func startMicrophoneRecording(deviceUID: String?) {
        let recorder = MicrophoneRecorder(deviceUID: deviceUID)
        // 不捕获 self（@MainActor）：AVAudioEngine 的 tap 回调在后台线程触发，
        // 捕获 MainActor 会导致隔离断言 SIGTRAP。直接捕获 queue 和 writer。
        let recordingQueue = self.queue
        recorder.onSampleBuffer = { [weak writer, recordingQueue] sampleBuffer in
            guard let writer else { return }
            recordingQueue.async {
                writer.appendMicrophone(sampleBuffer)
            }
        }
        self.microphoneRecorder = recorder
        do {
            try recorder.start()
            isMicrophoneActive = true
        } catch {
            logger.error("microphone start failed: \(error.localizedDescription)")
            stopMicrophoneRecording()
            isMicrophoneActive = false
        }
    }

    private func stopMicrophoneRecording() {
        microphoneRecorder?.stop()
        microphoneRecorder = nil
    }

    // MARK: - 暂停

    /// 暂停：丢帧，并把恢复后的 PTS 整体前移（成片里看不出这段）。
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        writer?.pause()
        microphoneRecorder?.pause()
        pausedAt = Date()
    }

    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        if let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
        writer?.resume()
        if isMicrophoneActive {
            do {
                try microphoneRecorder?.resume()
            } catch {
                logger.error("microphone resume failed: \(error.localizedDescription)")
            }
        }
    }

    /// 收工并交付：停流 → 排空队列 → 结束写入 → 回临时文件路径。
    func stop() async {
        guard isRunning else { return }
        isRunning = false
        if !(await finishCurrentSession()) {
            onFail?(Failure.noFrames)
        }
    }

    /// 取消：停流、删掉临时文件、不回调。
    func cancel() async {
        guard isRunning else { return }
        isRunning = false
        stopTicker()
        stopMicrophoneRecording()
        await stopStream()
        writer?.cancel()
        cleanUp()
    }

    /// 采集流自己断了（切显示器、系统掐流）：**能救就救**——已经写进去的帧先成片，
    /// 用户录了半天不该因为流抖一下就全丢。一帧都没有才算失败。
    private func handleStreamStopped(_ error: Error) {
        guard isRunning else { return }
        isRunning = false
        logger.error("stream stopped: \(error.localizedDescription)")
        Task { @MainActor in
            if !(await finishCurrentSession()) {
                onFail?(Failure.stream(error))
            }
        }
    }

    /// 停流 → 排空回调 → 结束写入。返回是否已经交付（false = 调用方去报错）。
    @discardableResult
    private func finishCurrentSession() async -> Bool {
        stopTicker()
        stopMicrophoneRecording()
        await stopStream()
        defer { cleanUp() }
        guard let writer else { return false }
        do {
            try await writer.finish()
            onFinish?(writer.url)
            return true
        } catch {
            logger.error("finish failed: \(error.localizedDescription)")
            writer.cancel()
            return false
        }
    }

    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func cleanUp() {
        stream = nil
        output = nil
        writer = nil
        microphoneRecorder = nil
        isMicrophoneActive = false
        startedAt = nil
        isPaused = false
        pausedAt = nil
        pausedTotal = 0
    }

    /// 停流 + 排空回调 + 摘掉 output（顺序不能反：先停流，再排空，最后才 finish writer）。
    private func stopStream() async {
        if let stream {
            try? await stream.stopCapture()
        }
        output = nil
        // 屏障：把还在飞的采样回调排干净，之后 writer 的状态就静止了。
        queue.sync {}
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, let startedAt = self.startedAt else { return }
                var elapsed = Date().timeIntervalSince(startedAt) - self.pausedTotal
                if let pausedAt = self.pausedAt {
                    elapsed -= Date().timeIntervalSince(pausedAt)
                }
                self.onTick?(max(0, elapsed))
            }
        }
    }

    /// 临时文件：真正落到保存目录是调用方的事（那边才有命名模板 / 同名序号）。
    static func makeTemporaryURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let token = ProcessInfo.processInfo.globallyUniqueString.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Jietu-\(formatter.string(from: Date()))-\(token).mp4")
    }
}

/// `SCStream` 的 delegate / output：只做转发。
///
/// 回调跑在宿主给的那条串行队列上（`RecordingEngine.queue`），
/// 所以这里**不许**往主线程 dispatch —— `stopStream()` 里的 `queue.sync {}` 屏障
/// 一旦遇到主线程等待就会死锁。
///
/// @author ygw
nonisolated final class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onScreenFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    /// 系统声音（SCStream `.audio`）。
    var onSystemAudio: (@Sendable (CMSampleBuffer) -> Void)?
    var onStopped: (@Sendable (Error) -> Void)?

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer, createIfNecessary: false
                ) as? [[SCStreamFrameInfo: Any]],
                let status = attachments.first?[.status] as? Int,
                status == SCFrameStatus.complete.rawValue,
                let pixelBuffer = sampleBuffer.imageBuffer
            else { return }
            onScreenFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        case .audio:
            guard sampleBuffer.numSamples > 0 else { return }
            onSystemAudio?(sampleBuffer)
        case .microphone:
            // 不走 SCK 的 microphone——capcap 走 AVAudioEngine（MicrophoneRecorder），更可靠。
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}
