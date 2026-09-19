import AudioToolbox
import AVFoundation
import CoreMedia

/// 通过 AVAudioEngine 采集麦克风，转成 CMSampleBuffer 交给 Writer 写入独立音轨。
///
/// SCStream **没有**可靠的麦克风采集——macOS 15 的 `captureMicrophone` 与 `.audio`
/// 分开交付，两路合到一个 AVAssetWriterInput 会因为时间戳重叠丢数据。
/// capcap 也走这条 AVAudioEngine 路。
///
/// 输出格式：Int16 单声道 44.1kHz（和系统声分开的轨道，编码成 AAC 单声道）。
/// PTS 用 `CMClockGetHostTimeClock` 打——与 SCStream 的帧在同一时钟域，
/// RecordingWriter 可以对齐。
///
/// 所有方法均在主线程（`@MainActor`）调用。`onSampleBuffer` 回调在 AVAudioEngine
/// 的内部线程触发，调用方把它 dispatch 到录制队列上。
///
/// @author ygw
final class MicrophoneRecorder {

    enum RecorderError: LocalizedError {
        case audioUnitUnavailable
        case inputFormatUnavailable
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .audioUnitUnavailable:
                return "指定的麦克风不可用"
            case .inputFormatUnavailable:
                return "麦克风输入格式不可用"
            case .converterUnavailable:
                return "音频格式转换器创建失败"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    /// 输出格式：Int16 单声道 44.1kHz。
    private let outputFormat: AVAudioFormat
    /// 指定麦克风的 CoreAudio UID（nil = 系统默认输入）。
    private let deviceUID: String?
    private var paused = false
    private var tapInstalled = false

    /// 每拿到一块 PCM 就回调（在 AVAudioEngine 的内部线程上，非主线程）。
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    init(deviceUID: String?) {
        self.deviceUID = deviceUID
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44_100,
            channels: 1,
            interleaved: true
        )!
    }

    /// 启动采集。失败时抛异常让上层降级（控制条显示「麦克风不可用」）。
    func start() throws {
        // 如果用户选了特定设备，先切 AudioUnit 的输入源——
        // format 查询依赖设备，必须先切。
        if let deviceUID, let deviceID = AudioInputDevices.deviceID(forUID: deviceUID) {
            guard let audioUnit = engine.inputNode.audioUnit else {
                throw RecorderError.audioUnitUnavailable
            }
            var id = deviceID
            _ = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
        }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.inputFormatUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        do {
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
                [weak self] buffer, _ in
                self?.handle(buffer: buffer)
            }
            tapInstalled = true
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func pause() {
        guard !paused else { return }
        paused = true
        engine.pause()
    }

    func resume() throws {
        guard paused else { return }
        try engine.start()
        paused = false
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        paused = false
    }

    // MARK: - 内部

    /// 拿到一块 AVAudioPCMBuffer → 转格式 → 包成 CMSampleBuffer → 回调。
    private func handle(buffer: AVAudioPCMBuffer) {
        guard !paused else { return }

        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate
        )
        guard frameCapacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity)
        else { return }

        var conversionError: NSError?
        var supplied = false
        guard let converter else { return }
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil else { return }

        if let sampleBuffer = Self.makeSampleBuffer(from: converted, format: outputFormat) {
            onSampleBuffer?(sampleBuffer)
        }
    }

    /// AVAudioPCMBuffer → CMSampleBuffer（Int16 PCM + HostTime PTS）。
    private static func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        format: AVAudioFormat
    ) -> CMSampleBuffer? {
        var formatDescription: CMAudioFormatDescription?
        var basicDescription = format.streamDescription.pointee
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &basicDescription,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return nil }

        let dataByteSize = Int(buffer.frameLength)
            * Int(format.streamDescription.pointee.mBytesPerFrame)
        guard dataByteSize > 0,
              let channelData = buffer.int16ChannelData?[0]
        else { return nil }

        // 拷贝 PCM 数据到 CMBlockBuffer（AVAudioPCMBuffer 的内存可能被重用）。
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: dataByteSize, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: dataByteSize,
            flags: 0, blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        guard CMBlockBufferReplaceDataBytes(
            with: channelData, blockBuffer: block,
            offsetIntoDestination: 0, dataLength: dataByteSize
        ) == kCMBlockBufferNoErr else { return nil }

        let sampleSize = Int(format.streamDescription.pointee.mBytesPerFrame)
        var sampleSizes = [sampleSize]
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sb = sampleBuffer else { return nil }

        // 用 HostTime 时钟打 PTS——与 SCStream 共时钟域。
        let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var timedBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sb,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &timedBuffer
        )
        return timedBuffer ?? sb
    }
}
