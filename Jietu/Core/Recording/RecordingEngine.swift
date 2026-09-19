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
/// @author ixxxxoooo
@MainActor
final class RecordingEngine {
    struct Options {
        /// 帧率（`minimumFrameInterval` = 1/fps）。
        var fps: Int = 30
        /// 录系统声音（页面里的视频、音乐）。
        var capturesSystemAudio = false
        /// 录麦克风（权限由调用方先申请；没设备 / 起不来会自动降级成无麦克风）。
        var capturesMicrophone = false
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
    private var microphone: MicrophoneCapture?
    private var ticker: Timer?

    private(set) var isRunning = false
    private(set) var isPaused = false
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
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.sampleRate = 44_100
        configuration.channelCount = 2

        // 只排除自家的控制条 / 红框，别的 Jietu 窗口（比如钉图）照常入镜。
        let excluded = content.windows.filter {
            excludingWindowNumbers.contains(Int($0.windowID))
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let url = Self.makeTemporaryURL()
        // 麦克风起不来（没设备 / 没授权就不该到这）就降级成无麦克风继续录。
        if options.capturesMicrophone {
            let mic = MicrophoneCapture()
            do {
                try mic.start()
                microphone = mic
            } catch {
                logger.error("microphone unavailable, recording without it: \(error.localizedDescription)")
            }
        }
        let writer = try RecordingWriter(
            url: url,
            width: dimensions.width,
            height: dimensions.height,
            fps: fps,
            withSystemAudio: options.capturesSystemAudio,
            withMicrophone: microphone != nil
        )
        if let microphone {
            microphone.onBuffer = { @Sendable buffer, pts in
                writer.appendMicrophone(buffer, at: pts)
            }
        }
        let output = RecordingStreamOutput()
        output.onScreenFrame = { [writer] pixelBuffer, time in
            writer.append(pixelBuffer: pixelBuffer, at: time)
        }
        output.onAudioSample = { [writer] sampleBuffer in
            writer.append(audio: sampleBuffer)
        }
        output.onStopped = { [weak self] error in
            // SCK 不保证这个回调在主线程上：跳过去，别 assumeIsolated（不同线程会 trap）。
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
        startTicker()
        logger.notice(
            "recording \(dimensions.width)x\(dimensions.height)@\(fps) audio=\(options.capturesSystemAudio) mic=\(self.microphone != nil)"
        )
    }

    /// 暂停：丢帧，并把恢复后的 PTS 整体前移（成片里看不出这段）。
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        // 直接调（writer 内部用锁护住暂停状态）：**别** queue.async 过去——
        // 闭包会继承 MainActor 隔离，丢到后台队列上跑会触发运行时的隔离断言（实测 SIGTRAP）。
        writer?.pause()
        // 计时：暂停时把这一段的起点记下，tick 里扣掉。
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
        microphone?.onBuffer = nil
        microphone?.stop()
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
        // 麦克风先停：tap 摘掉之后 writer 才可能安全 finish（没有采样还在飞）。
        microphone?.onBuffer = nil
        microphone?.stop()
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
        microphone = nil
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
/// @author ixxxxoooo
nonisolated final class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    // 三个回调都必须是 `@Sendable`：它们是在 `@MainActor` 的 `start(...)` 里赋值的，
    // 不标的话闭包会**继承 MainActor 隔离**，而 SCK 把它们调到采集队列上 → 运行时隔离断言
    // 直接 trap（实测 SIGTRAP，且没有任何输出，很难查）。
    var onScreenFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    var onAudioSample: (@Sendable (CMSampleBuffer) -> Void)?
    var onStopped: (@Sendable (Error) -> Void)?

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            // 只有 `.complete` 的帧才画得动：`.idle` / `.blank` 是占位帧。
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
            onAudioSample?(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }
}

