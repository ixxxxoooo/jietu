import AVFoundation
import Foundation
import Synchronization

/// 写 mp4 的那只手：所有方法都在 `RecordingEngine.queue` 上调用（`@unchecked Sendable` 靠这条纪律）。
///
/// **双音轨**：系统声音和麦克风各自一条 AAC 轨（参考 capcap）——
/// 播放器（QuickTime / VLC / 系统预览）同时播两轨，不需要手动混音。
/// 哪一轨从头到尾没收到过数据，writer 会在 finish 时自动丢掉那条空轨。
///
/// @author ygw
nonisolated final class RecordingWriter: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    // macOS 26+ 的 receiver 模型：输入由 writer 直接发放强类型的「接收器」，
    // 取代 `isReadyForMoreMediaData` + `append` 的轮询写法（macOS 27 起旧接口已弃用）。
    private let videoReceiver: AVAssetWriterInput.PixelBufferReceiver
    private var systemAudioReceiver: AVAssetWriterInput.SampleBufferReceiver?
    private var microphoneReceiver: AVAssetWriterInput.SampleBufferReceiver?

    /// 会话起点只能定一次；暂停 / 采集在不同线程上，所以用 `Mutex` 护着。
    private let sessionStarted = Mutex(false)
    private var hasWrittenFrame = false
    private var hasWrittenSystemAudio = false
    private var hasWrittenMicrophone = false

    /// 会话锚点 PTS——静音填充的起始参考。
    private var referenceAnchor: CMTime?
    /// 系统声最后一块样本的结束时间。
    private var lastSystemAudioEndTime: CMTime?
    /// 麦克风最后一块样本的结束时间。
    private var lastMicrophoneEndTime: CMTime?

    /// 暂停状态：写帧在采集队列上、暂停/恢复在主线程上，两边都要看它，
    /// 用 `Mutex`（`Synchronization`）护着，比 `NSLock` 少一次手工配对。
    private struct PauseState {
        var isPaused = false
        /// 暂停累计了多久（**挂钟秒**，不是帧时间戳）。
        var totalSeconds: Double = 0
        var pausedAtWall: Double?
    }
    private let pauseState = Mutex(PauseState())

    /// 现在是不是暂停中（跨线程安全）。
    private var isPausedNow: Bool {
        pauseState.withLock { $0.isPaused }
    }

    init(
        url: URL, width: Int, height: Int, fps: Int,
        withSystemAudio: Bool,
        withMicrophone: Bool
    ) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let dimensions = VideoEncodingSettings.evenDimensions(width: width, height: height)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: VideoEncodingSettings.outputSettings(
                width: dimensions.width, height: dimensions.height, fps: fps
            )
        )
        guard writer.canAdd(videoInput) else {
            throw RecordingEngine.Failure.startFailed({
                let r = CFBundleCopyLocalizedString(
                    CFBundleGetMainBundle(), "writer_error.video_track" as CFString,
                    "writer_error.video_track" as CFString, "Localizable" as CFString
                )
                return r as String? ?? "writer_error.video_track"
            }())
        }
        videoReceiver = writer.inputPixelBufferReceiver(
            for: videoInput,
            pixelBufferAttributes: CVPixelBufferCreationAttributes(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                size: CVImageSize(width: dimensions.width, height: dimensions.height)
            )
        )

        // 系统声：AAC 立体声 44.1kHz
        if withSystemAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: VideoEncodingSettings.systemAudioOutputSettings()
            )
            if writer.canAdd(input) {
                systemAudioReceiver = writer.inputReceiver(for: input)
            }
        }

        // 麦克风：AAC 单声道 44.1kHz（独立音轨）
        if withMicrophone {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: VideoEncodingSettings.microphoneOutputSettings()
            )
            if writer.canAdd(input) {
                microphoneReceiver = writer.inputReceiver(for: input)
            }
        }

        do {
            try writer.start()
        } catch {
            throw RecordingEngine.Failure.writer(writer.error ?? error)
        }
    }

    // MARK: - 写帧

    func append(pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard !isPausedNow else { return }
        let stamp = adjusted(time)
        startSessionIfNeeded(at: stamp)
        // 实时写入：接收器没准备好就丢帧（返回 false），不排队、不阻塞采集队列。
        nonisolated(unsafe) let unsafeBuffer = pixelBuffer
        let readOnly = CVReadOnlyPixelBuffer(unsafeBuffer: unsafeBuffer)
        if (try? videoReceiver.appendImmediately(readOnly, with: stamp)) == true {
            hasWrittenFrame = true
        }
    }

    /// 系统声音（SCStream `.audio` 交付的 CMSampleBuffer）。
    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !isPausedNow, sampleBuffer.numSamples > 0, let receiver = systemAudioReceiver else { return }
        let stamp = adjusted(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        startSessionIfNeeded(at: stamp)

        // 填充静音间隙（避免两轨起点不对齐导致播放器偏移）
        let gapStart = lastSystemAudioEndTime ?? referenceAnchor
        if let gapStart, CMTimeCompare(gapStart, stamp) < 0 {
            fillSilence(into: receiver, like: sampleBuffer, from: gapStart, to: stamp)
        }

        guard let restamped = Self.restamped(sampleBuffer, to: stamp) else { return }
        if (try? receiver.appendImmediately(Self.ready(restamped))) == true {
            hasWrittenSystemAudio = true
            lastSystemAudioEndTime = sampleEndTime(pts: stamp, sampleBuffer: restamped)
        }
    }

    /// 麦克风（MicrophoneRecorder 交付的、可跨线程传递的样本）。
    func appendMicrophone(_ ready: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>) {
        ready.withUnsafeSampleBuffer { appendMicrophone($0) }
    }

    /// 麦克风样本（已在录制队列上）。
    private func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard !isPausedNow, sampleBuffer.numSamples > 0, let receiver = microphoneReceiver else { return }
        let stamp = adjusted(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        startSessionIfNeeded(at: stamp)

        // 填充静音间隙
        let gapStart = lastMicrophoneEndTime ?? referenceAnchor
        if let gapStart, CMTimeCompare(gapStart, stamp) < 0 {
            fillSilence(into: receiver, like: sampleBuffer, from: gapStart, to: stamp)
        }

        guard let restamped = Self.restamped(sampleBuffer, to: stamp) else { return }
        if (try? receiver.appendImmediately(Self.ready(restamped))) == true {
            hasWrittenMicrophone = true
            lastMicrophoneEndTime = sampleEndTime(pts: stamp, sampleBuffer: restamped)
        }
    }

    /// 第一帧的 PTS 作为会话起点，后面都相对它（否则首帧会带一大段空白）。
    private func startSessionIfNeeded(at time: CMTime) {
        let shouldStart = sessionStarted.withLock { started in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        referenceAnchor = time
        writer.startSession(atSourceTime: time)
    }

    // MARK: - 暂停

    func pause() {
        pauseState.withLock { state in
            guard !state.isPaused else { return }
            state.isPaused = true
            state.pausedAtWall = CACurrentMediaTime()
        }
    }

    func resume() {
        pauseState.withLock { state in
            guard state.isPaused else { return }
            state.isPaused = false
            if let pausedAtWall = state.pausedAtWall {
                state.totalSeconds += CACurrentMediaTime() - pausedAtWall
            }
            state.pausedAtWall = nil
        }
    }

    /// 暂停期间的 PTS 整体前移：成片里看不出暂停过（也不留空档）。
    private func adjusted(_ time: CMTime) -> CMTime {
        let paused = pauseState.withLock { $0.totalSeconds }
        guard paused > 0 else { return time }
        return time - CMTime(seconds: paused, preferredTimescale: 600)
    }

    // MARK: - 收工

    var didWriteAnyFrame: Bool { hasWrittenFrame }

    /// 结束写入（调用前必须已经停流 + 排空队列）。
    func finish() async throws {
        guard hasWrittenFrame else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw RecordingEngine.Failure.noFrames
        }
        videoReceiver.finish()
        systemAudioReceiver?.finish()
        microphoneReceiver?.finish()
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

    /// 把采集到的 `CMSampleBuffer` 包成 `appendImmediately` 要的强类型 `CMReadySampleBuffer`。
    ///
    /// `unsafeBuffer:` 要求 `sending`（调用后不能再被别处改动）；这里的缓冲区都是
    /// 采集回调交付的只读样本，且写入全程在同一条串行队列上，不会并发改动，所以集中在这一处声明。
    private static func ready(
        _ buffer: CMSampleBuffer
    ) -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
        nonisolated(unsafe) let unsafeBuffer = buffer
        return CMReadySampleBuffer(unsafeBuffer: unsafeBuffer)
    }

    /// 换一个新的 PTS。
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

    /// 计算一块音频样本的结束时间。
    private func sampleEndTime(pts: CMTime, sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, CMTimeCompare(duration, .zero) > 0 {
            return CMTimeAdd(pts, duration)
        }
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mSampleRate > 0
        else { return pts }
        return CMTimeAdd(
            pts,
            CMTime(
                value: CMTimeValue(CMSampleBufferGetNumSamples(sampleBuffer)),
                timescale: CMTimeScale(asbd.mSampleRate)
            )
        )
    }

    /// 用零值 PCM 填充 [start, end) 的间隙——保证两条音轨从同一起点开始，
    /// 播放器不会因为一轨起步晚而偏移。
    private func fillSilence(
        into receiver: AVAssetWriterInput.SampleBufferReceiver,
        like reference: CMSampleBuffer,
        from start: CMTime,
        to end: CMTime
    ) {
        guard start.isValid, end.isValid, CMTimeCompare(start, end) < 0,
              let fmt = CMSampleBufferGetFormatDescription(reference),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mSampleRate > 0
        else { return }

        let framesPerChunk = max(1, CMSampleBufferGetNumSamples(reference))
        let duration = CMTimeSubtract(end, start)
        let durationInFrames = CMTimeConvertScale(
            duration, timescale: CMTimeScale(asbd.mSampleRate), method: .roundTowardZero
        )
        guard durationInFrames.value > 0 else { return }

        var remaining = Int(durationInFrames.value)
        var cursor = start
        while remaining > 0 {
            let count = min(remaining, framesPerChunk)
            guard let silent = Self.makeSilence(
                formatDescription: fmt, asbd: asbd,
                at: cursor, frameCount: count,
                referenceBuffer: reference
            ), (try? receiver.appendImmediately(Self.ready(silent))) == true
            else { return }
            cursor = CMTimeAdd(
                cursor,
                CMTime(value: CMTimeValue(count), timescale: CMTimeScale(asbd.mSampleRate))
            )
            remaining -= count
        }
    }

    /// 构造一块全零 PCM 样本。
    private static func makeSilence(
        formatDescription: CMAudioFormatDescription,
        asbd: AudioStreamBasicDescription,
        at pts: CMTime,
        frameCount: Int,
        referenceBuffer: CMSampleBuffer
    ) -> CMSampleBuffer? {
        guard let sourceBlock = CMSampleBufferGetDataBuffer(referenceBuffer) else { return nil }
        let refLength = CMBlockBufferGetDataLength(sourceBlock)
        let refFrameCount = CMSampleBufferGetNumSamples(referenceBuffer)
        guard refLength > 0, refFrameCount > 0, frameCount > 0 else { return nil }
        let bytesPerFrame = refLength / refFrameCount
        let length = bytesPerFrame * frameCount
        guard bytesPerFrame > 0, length > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: 0, blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }
        guard CMBlockBufferFillDataBytes(
            with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length
        ) == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
}
