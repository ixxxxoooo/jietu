import AVFoundation
import Foundation

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
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var hasWrittenFrame = false
    private var hasWrittenSystemAudio = false
    private var hasWrittenMicrophone = false

    /// 会话锚点 PTS——静音填充的起始参考。
    private var referenceAnchor: CMTime?
    /// 系统声最后一块样本的结束时间。
    private var lastSystemAudioEndTime: CMTime?
    /// 麦克风最后一块样本的结束时间。
    private var lastMicrophoneEndTime: CMTime?

    /// 暂停状态用锁护着：写帧在采集队列上、暂停/恢复在主线程上，两边都要看它。
    private let pauseLock = NSLock()
    private var isPaused = false
    /// 会话起点上锁。
    private let sessionLock = NSLock()

    /// 现在是不是暂停中（跨线程安全）。
    private var isPausedNow: Bool {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        return isPaused
    }

    /// 暂停累计了多久（**挂钟秒**，不是帧时间戳）。
    private var pausedTotalSeconds: Double = 0
    private var pausedAtWall: Double?

    init(
        url: URL, width: Int, height: Int, fps: Int,
        withSystemAudio: Bool,
        withMicrophone: Bool
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
            throw RecordingEngine.Failure.startFailed({
                let r = CFBundleCopyLocalizedString(
                    CFBundleGetMainBundle(), "writer_error.video_track" as CFString,
                    "writer_error.video_track" as CFString, "Localizable" as CFString
                )
                return r as String? ?? "writer_error.video_track"
            }())
        }
        writer.add(videoInput)

        // 系统声：AAC 立体声 44.1kHz
        if withSystemAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: VideoEncodingSettings.systemAudioOutputSettings()
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                systemAudioInput = input
            }
        }

        // 麦克风：AAC 单声道 44.1kHz（独立音轨）
        if withMicrophone {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: VideoEncodingSettings.microphoneOutputSettings()
            )
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                microphoneInput = input
            }
        }

        guard writer.startWriting() else {
            throw RecordingEngine.Failure.writer(
                writer.error ?? RecordingEngine.Failure.startFailed({
                    let r = CFBundleCopyLocalizedString(
                        CFBundleGetMainBundle(), "writer_error.start_writing" as CFString,
                        "writer_error.start_writing" as CFString, "Localizable" as CFString
                    )
                    return r as String? ?? "writer_error.start_writing"
                }())
            )
        }
    }

    // MARK: - 写帧

    func append(pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard !isPausedNow else { return }
        let stamp = adjusted(time)
        startSessionIfNeeded(at: stamp)
        guard videoInput.isReadyForMoreMediaData else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: stamp) {
            hasWrittenFrame = true
        }
    }

    /// 系统声音（SCStream `.audio` 交付的 CMSampleBuffer）。
    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !isPausedNow, sampleBuffer.numSamples > 0, let input = systemAudioInput else { return }
        let stamp = adjusted(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        startSessionIfNeeded(at: stamp)

        // 填充静音间隙（避免两轨起点不对齐导致播放器偏移）
        let gapStart = lastSystemAudioEndTime ?? referenceAnchor
        if let gapStart, CMTimeCompare(gapStart, stamp) < 0 {
            fillSilence(into: input, like: sampleBuffer, from: gapStart, to: stamp)
        }

        guard let restamped = Self.restamped(sampleBuffer, to: stamp) else { return }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(restamped) {
            hasWrittenSystemAudio = true
            lastSystemAudioEndTime = sampleEndTime(pts: stamp, sampleBuffer: restamped)
        }
    }

    /// 麦克风（MicrophoneRecorder 交付的 CMSampleBuffer）。
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard !isPausedNow, sampleBuffer.numSamples > 0, let input = microphoneInput else { return }
        let stamp = adjusted(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        startSessionIfNeeded(at: stamp)

        // 填充静音间隙
        let gapStart = lastMicrophoneEndTime ?? referenceAnchor
        if let gapStart, CMTimeCompare(gapStart, stamp) < 0 {
            fillSilence(into: input, like: sampleBuffer, from: gapStart, to: stamp)
        }

        guard let restamped = Self.restamped(sampleBuffer, to: stamp) else { return }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(restamped) {
            hasWrittenMicrophone = true
            lastMicrophoneEndTime = sampleEndTime(pts: stamp, sampleBuffer: restamped)
        }
    }

    /// 第一帧的 PTS 作为会话起点，后面都相对它（否则首帧会带一大段空白）。
    private func startSessionIfNeeded(at time: CMTime) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard !sessionStarted else { return }
        sessionStarted = true
        referenceAnchor = time
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

    /// 结束写入（调用前必须已经停流 + 排空队列）。
    func finish() async throws {
        guard hasWrittenFrame else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw RecordingEngine.Failure.noFrames
        }
        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
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
        into input: AVAssetWriterInput,
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
            guard input.isReadyForMoreMediaData else { return }
            let count = min(remaining, framesPerChunk)
            guard let silent = Self.makeSilence(
                formatDescription: fmt, asbd: asbd,
                at: cursor, frameCount: count,
                referenceBuffer: reference
            ), input.append(silent)
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
