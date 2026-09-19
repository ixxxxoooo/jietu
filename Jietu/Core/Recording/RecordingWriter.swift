import AVFoundation
import Foundation

/// 写 mp4 的那只手：所有方法都在 `RecordingEngine.queue` 上调用（`@unchecked Sendable` 靠这条纪律）。
///
/// 音频走**直写**：SCK 已经把系统声与麦克风混好了（`captureMicrophone`），
/// 这边只管改时间戳就写进去，不做任何 PCM 转换或手动混音。
///
/// @author ixxxxoooo
nonisolated final class RecordingWriter: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var hasWrittenFrame = false
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
    ///
    /// 用挂钟而不是「最后一帧的 PTS」：静止画面里帧是稀疏的，拿帧 PTS 当锚点会把
    /// 「最后一帧 → 按下暂停」这段真实时间也一起吞掉（实测暂停 1.2s 却抽掉了 1.7s）。
    private var pausedTotalSeconds: Double = 0
    private var pausedAtWall: Double?

    init(url: URL, width: Int, height: Int, fps: Int, withAudio: Bool) throws {
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

        if withAudio {
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
        guard videoInput.isReadyForMoreMediaData else { return }
        if adaptor.append(pixelBuffer, withPresentationTime: stamp) {
            hasWrittenFrame = true
        }
    }

    /// 音频（SCK 交付的 CMSampleBuffer，系统声 + 麦克风已混好）。
    func append(audio sampleBuffer: CMSampleBuffer) {
        guard !isPausedNow, sampleBuffer.numSamples > 0, let audioInput else { return }
        let stamp = adjusted(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard let restamped = Self.restamped(sampleBuffer, to: stamp) else { return }
        startSessionIfNeeded(at: stamp)
        guard audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(restamped)
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

    /// 结束写入（调用前必须已经停流 + 排空队列）。
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
