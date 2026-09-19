import AVFoundation
import Foundation

/// 写 mp4 的那只手：所有方法都在 `RecordingEngine.queue` 上调用（`@unchecked Sendable` 靠这条纪律）。
///
/// **例外**是麦克风：`appendMicrophone` 跑在 AVAudioEngine 的 tap 线程上——
/// 它只用锁护住的状态（暂停 / 会话起点 / 混音器），不碰别的可变字段。
/// 音频进一条 AAC 轨：单源直写；系统声 + 麦克风双开时先过 `RealtimeAudioMixer` 混成一路
/// （mp4 放两条音轨播放器只出第一条，必须在写入前混）。
///
/// @author ixxxxoooo
nonisolated final class RecordingWriter: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInput: AVAssetWriterInput?
    /// 双源混音器（只在与麦克风同时启用时存在）。
    private var mixer: RealtimeAudioMixer?
    /// 系统声的源格式与配套转换器（只在采集队列上使用）。
    private var systemAudioFormat: AVAudioFormat?
    private var systemAudioConverter: AVAudioConverter?

    private var sessionStarted = false
    private var hasWrittenFrame = false
    /// 暂停状态用锁护着：写帧在采集队列上、暂停/恢复在主线程上，两边都要看它。
    private let pauseLock = NSLock()
    private var isPaused = false
    /// 会话起点在采集队列与麦克风 tap 线程两边都可能设，同样上锁。
    private let sessionLock = NSLock()

    /// 现在是不是暂停中（跨线程安全）。
    private var isPausedNow: Bool {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        return isPaused
    }
    /// 暂停累计了多久（**挂钟秒**，不是帧时间戳）。
    ///
    /// 用挂钟而不是「最后一帧的 PTS」：静止画面里帧是稀疏的，拿帧 PTS 当锚点会把
    /// 「最后一帧 → 按下暂停」这段真实时间也一起吞掉（实测暂停 1.2s 却抽掉了 1.7s）。
    private var pausedTotalSeconds: Double = 0
    private var pausedAtWall: Double?

    init(
        url: URL, width: Int, height: Int, fps: Int,
        withSystemAudio: Bool, withMicrophone: Bool
    ) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let dimensions = VideoEncodingSettings.evenDimensions(width: width, height: height)
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: VideoEncodingSettings.outputSettings(
                width: dimensions.width, height: dimensions.height, fps: fps
            )
        )
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dimensions.width,
                kCVPixelBufferHeightKey as String: dimensions.height,
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw RecordingEngine.Failure.startFailed("视频轨加不进去")
        }
        writer.add(videoInput)

        if withSystemAudio || withMicrophone {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: VideoEncodingSettings.systemAudioOutputSettings()
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        if withSystemAudio, withMicrophone {
            mixer = RealtimeAudioMixer()
        }

        guard writer.startWriting() else {
            throw RecordingEngine.Failure.writer(
                writer.error ?? RecordingEngine.Failure.startFailed("startWriting 失败")
            )
        }
    }

    // MARK: - 写帧

    func append(pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard !isPausedNow else { return }
        let stamp = adjusted(time)
        startSessionIfNeeded(at: stamp)
        // 写不动就丢这一帧：录屏宁可掉帧，也不能把主线程/队列堵住。
        guard videoInput.isReadyForMoreMediaData else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: stamp) {
            hasWrittenFrame = true
        }
    }

    /// 系统声音（SCK 交付的 CMSampleBuffer，采集队列上调用）。
    func append(audio sampleBuffer: CMSampleBuffer) {
        guard !isPausedNow, sampleBuffer.numSamples > 0, let audioInput else { return }
        let stamp = adjusted(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard
            let pcm = AudioSampleBufferFactory.pcmBuffer(from: sampleBuffer)
        else { return }

        if let mixer {
            // 双源：统一格式 → 入混音队列 → 排空到这一拍的结尾。
            if systemAudioFormat == nil { systemAudioFormat = pcm.format }
            let target = convertIfNeeded(pcm)
            guard let target else { return }
            mixer.enqueue(.system, buffer: target, at: stamp)
            drainMixer(until: stamp + Self.duration(of: target), into: audioInput)
        } else {
            // 单源（只系统声）：老路，改时间戳直接写。
            guard let restamped = Self.restamped(sampleBuffer, to: stamp) else { return }
            startSessionIfNeeded(at: stamp)
            guard audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(restamped)
        }
    }

    /// 麦克风（AVAudioEngine tap 线程上调用；buffer 已经是目标格式）。
    func appendMicrophone(_ buffer: AVAudioPCMBuffer, at pts: CMTime) {
        guard !isPausedNow, let audioInput else { return }
        let stamp = adjusted(pts)
        if let mixer {
            mixer.enqueue(.microphone, buffer: buffer, at: stamp)
            // 麦克风这一拍也推一把：系统声万一停了（静音 / 流断），麦克风照常进轨。
            drainMixer(until: stamp + Self.duration(of: buffer), into: audioInput)
        } else {
            startSessionIfNeeded(at: stamp)
            guard audioInput.isReadyForMoreMediaData else { return }
            if let sample = AudioSampleBufferFactory.sampleBuffer(from: buffer, at: stamp) {
                audioInput.append(sample)
            }
        }
    }

    /// 把混音器排到 `until`，逐块打上 PTS 写进音频轨。
    private func drainMixer(until end: CMTime, into audioInput: AVAssetWriterInput) {
        for chunk in mixer!.drain(until: end) {
            startSessionIfNeeded(at: chunk.pts)
            guard audioInput.isReadyForMoreMediaData,
                let sample = AudioSampleBufferFactory.sampleBuffer(
                    from: chunk.buffer, at: chunk.pts
                )
            else { continue }
            audioInput.append(sample)
        }
    }

    /// 第一帧的 PTS 作为会话起点，后面都相对它（否则首帧会带一大段空白）。
    private func startSessionIfNeeded(at time: CMTime) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard !sessionStarted else { return }
        sessionStarted = true
        writer.startSession(atSourceTime: time)
    }

    // MARK: - 暂停

    func pause() {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        guard !isPaused else { return }
        isPaused = true
        pausedAtWall = CACurrentMediaTime()
    }

    func resume() {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        guard isPaused else { return }
        isPaused = false
        if let pausedAtWall {
            pausedTotalSeconds += CACurrentMediaTime() - pausedAtWall
        }
        pausedAtWall = nil
    }

    /// 暂停期间的 PTS 整体前移：成片里看不出暂停过（也不留空档）。
    private func adjusted(_ time: CMTime) -> CMTime {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        guard pausedTotalSeconds > 0 else { return time }
        return time - CMTime(seconds: pausedTotalSeconds, preferredTimescale: 600)
    }

    // MARK: - 收工

    var didWriteAnyFrame: Bool { hasWrittenFrame }

    /// 结束写入（调用前必须已经停流 + 排空队列 + 停麦克风）。
    func finish() async throws {
        guard hasWrittenFrame else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw RecordingEngine.Failure.noFrames
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error {
            try? FileManager.default.removeItem(at: url)
            throw RecordingEngine.Failure.writer(error)
        }
    }

    /// 放弃这次录制：取消写入并删掉临时文件。
    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 私有

    /// 系统声格式对不上目标格式时转一次（converter 记住复用）。
    private func convertIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format != RecordingAudioFormat.format, let format = systemAudioFormat
        else { return buffer }
        if systemAudioConverter == nil {
            systemAudioConverter = AVAudioConverter(from: format, to: RecordingAudioFormat.format)
        }
        guard let converter = systemAudioConverter else { return nil }
        return AudioSampleBufferFactory.converted(buffer, from: format, using: converter)
    }

    private static func duration(of buffer: AVAudioPCMBuffer) -> CMTime {
        CMTime(
            value: CMTimeValue(buffer.frameLength),
            timescale: CMTimeScale(buffer.format.sampleRate)
        )
    }

    /// 换一个新的 PTS（`CMSampleBufferCreateCopyWithNewTiming` 会复制一份，原件照旧释放）。
    private static func restamped(_ sampleBuffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }
}
