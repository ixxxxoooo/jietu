import AVFoundation
import Testing
@testable import Jietu

/// 录屏双路混音（`RealtimeAudioMixer`）与 `AudioSampleBufferFactory` 互转。
/// 麦克风采集 / 写盘链路分别由权限引导与 `--selftest-record` 端到端验。
///
/// @author ixxxxoooo
@Suite("录屏混音")
struct AudioMixerTests {

    // MARK: - 脚手架

    /// 造一块目标格式（44.1k/2ch/Float32 非交织）的 PCMBuffer，双声道填同一个常量。
    private func makeBuffer(frames: Int, value: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: RecordingAudioFormat.format, frameCapacity: AVAudioFrameCount(frames)
        )!
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(RecordingAudioFormat.channels) {
                for i in 0..<frames { channels[channel][i] = value }
            }
        }
        return buffer
    }

    /// 目标时间轴上的帧序号 → CMTime（timescale = 采样率）。
    private func time(atFrame frame: Int64) -> CMTime {
        CMTime(value: frame, timescale: CMTimeScale(RecordingAudioFormat.sampleRate))
    }

    /// 第一声道第 `index` 个采样（非交织格式下各声道一段连续内存）。
    private func sample(_ buffer: AVAudioPCMBuffer, channel: Int = 0, _ index: Int) -> Float {
        buffer.floatChannelData![channel][index]
    }

    /// 目标时间轴上的帧偏移 → CMTime。
    private func frames(_ count: Int64) -> CMTime {
        time(atFrame: count)
    }

    /// 排空后全部产物的采样数（chain 而不是一整行，崩了能定位是哪一段）。
    private func totalFrames(of chunks: [(pts: CMTime, buffer: AVAudioPCMBuffer)]) -> Int {
        chunks.reduce(0) { $0 + Int($1.buffer.frameLength) }
    }

    // MARK: - 混音

    @Test("第一拍从最早的一帧起步，早于它的区间不留白")
    func firstDrainStartsAtEarliestFrame() {
        let mixer = RealtimeAudioMixer()
        // 系统声从第 100 帧才来：第一拍从 100 起步，而不是从 0 补一大段静音。
        mixer.enqueue(.system, buffer: makeBuffer(frames: 28, value: 0.5), at: time(atFrame: 100))

        let chunks = mixer.drain(until: time(atFrame: 128))
        #expect(totalFrames(of: chunks) == 28)
        #expect(chunks.first?.pts == time(atFrame: 100))
        // 0.5 + 静音 = 0.5（不是翻倍、也不是 0）。
        #expect(sample(chunks.first!.buffer, 0) == 0.5)
        #expect(mixer.droppedLateFrames == 0)
    }

    @Test("两路重叠区间按采样相加")
    func overlappingSourcesAreSummed() {
        let mixer = RealtimeAudioMixer()
        mixer.enqueue(.system, buffer: makeBuffer(frames: 64, value: 0.25), at: time(atFrame: 0))
        mixer.enqueue(.microphone, buffer: makeBuffer(frames: 64, value: 0.25), at: time(atFrame: 0))

        let chunks = mixer.drain(until: time(atFrame: 64))
        #expect(chunks.reduce(0) { $0 + Int($1.buffer.frameLength) } == 64)
        for chunk in chunks {
            #expect(sample(chunk.buffer, 0) == 0.5)
            #expect(sample(chunk.buffer, channel: 1, 10) == 0.5)
        }
    }

    @Test("只开一路时照样成轨（麦克风独自推进）")
    func singleSourceProgresses() {
        let mixer = RealtimeAudioMixer()
        mixer.enqueue(.microphone, buffer: makeBuffer(frames: 32, value: -0.2), at: time(atFrame: 0))

        let chunks = mixer.drain(until: time(atFrame: 32))
        #expect(chunks.reduce(0) { $0 + Int($1.buffer.frameLength) } == 32)
        #expect(sample(chunks.first!.buffer, 0) == -0.2)
    }

    @Test("整条落在已输出区间之前的迟到采样被丢掉并记账")
    func lateSamplesAreDropped() {
        let mixer = RealtimeAudioMixer()
        mixer.enqueue(.system, buffer: makeBuffer(frames: 64, value: 0.5), at: time(atFrame: 0))
        _ = mixer.drain(until: time(atFrame: 64))

        // 这一块完全在「已输出到 64」之前：丢掉、不计进输出。
        mixer.enqueue(.system, buffer: makeBuffer(frames: 8, value: 1.0), at: time(atFrame: 16))
        mixer.enqueue(.system, buffer: makeBuffer(frames: 8, value: 0.25), at: time(atFrame: 64))
        let chunks = mixer.drain(until: time(atFrame: 72))
        #expect(mixer.droppedLateFrames == 8)
        #expect(sample(chunks.first!.buffer, 0) == 0.25)
    }

    @Test("暂停回退（时间轴整体前移）时混音器清空重来，不卡死在过去")
    func rewindOnTimelineShift() {
        let mixer = RealtimeAudioMixer()
        // 已录 10 秒（帧 441000 起），正常输出了一拍。
        let tenSeconds = Int64(RecordingAudioFormat.sampleRate) * 10
        mixer.enqueue(.system, buffer: makeBuffer(frames: 64, value: 0.5), at: time(atFrame: tenSeconds))
        _ = mixer.drain(until: time(atFrame: tenSeconds + 64))

        // 暂停 1.2 秒后恢复：写入方把 PTS 前移 1.2s，新采样帧序号比已输出位置早一大截。
        let shifted = tenSeconds + 64 - Int64(RecordingAudioFormat.sampleRate * 6 / 5)
        mixer.enqueue(.system, buffer: makeBuffer(frames: 32, value: 0.75), at: time(atFrame: shifted))
        #expect(mixer.droppedLateFrames == 0)
        let chunks = mixer.drain(until: time(atFrame: shifted + 32))
        #expect(totalFrames(of: chunks) == 32)
        #expect(chunks.first.map { sample($0.buffer, 0) } == 0.75)

        // 接着正常往前走：回退之后还能连续产出。
        mixer.enqueue(.system, buffer: makeBuffer(frames: 16, value: 0.1), at: time(atFrame: shifted + 32))
        let more = mixer.drain(until: time(atFrame: shifted + 48))
        #expect(totalFrames(of: more) == 16)
        #expect(more.first.map { sample($0.buffer, 0) } == 0.1)
    }

    // MARK: - CMSampleBuffer 互转

    @Test("SCK 侧音频 → PCM：采样值、帧数、PTS 都完整")
    func pcmBufferFromSampleBuffer() throws {
        // 生产路径：SCK 交付的 CMSampleBuffer（交织）→ PCMBuffer。
        // 自己手搭一个交织的音频 CMSampleBuffer 来模拟（工厂产的那只标的是非交织 ASBD，
        // 非交织喂不进 `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`）。
        let frames = 441
        let pts = time(atFrame: 12345)
        let sampleBuffer = try #require(
            Self.makeInterleavedSampleBuffer(frames: frames, value: 0.3, at: pts)
        )
        #expect(sampleBuffer.numSamples == frames)
        #expect(CMSampleBufferGetPresentationTimeStamp(sampleBuffer) == pts)

        let back = try #require(AudioSampleBufferFactory.pcmBuffer(from: sampleBuffer))
        #expect(Int(back.frameLength) == frames)
        #expect(back.format.channelCount == RecordingAudioFormat.channels)
        // 交织源（LRLR…）要拆成非交织的两个声道：两个声道都该读到 0.3。
        #expect(sample(back, channel: 0, 0) == 0.3)
        #expect(sample(back, channel: 0, frames - 1) == 0.3)
        #expect(sample(back, channel: 1, frames - 1) == 0.3)
    }

    /// 手搭一只交织（LRLR…）的音频 CMSampleBuffer，模拟 SCK 交付的那只。
    private static func makeInterleavedSampleBuffer(
        frames: Int, value: Float, at pts: CMTime
    ) -> CMSampleBuffer? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: RecordingAudioFormat.sampleRate,
            channels: RecordingAudioFormat.channels, interleaved: true
        )!
        var description: CMFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: format.streamDescription,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &description
            ) == noErr, let description
        else { return nil }

        var samples = [Float](repeating: value, count: frames * Int(RecordingAudioFormat.channels))
        let totalBytes = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: totalBytes,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: totalBytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer
            ) == kCMBlockBufferNoErr, let blockBuffer,
            samples.withUnsafeMutableBytes({ raw in
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!, blockBuffer: blockBuffer,
                    offsetIntoDestination: 0, dataLength: totalBytes
                )
            }) == kCMBlockBufferNoErr
        else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: CMTimeValue(frames), timescale: CMTimeScale(RecordingAudioFormat.sampleRate)
            ),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
            ) == noErr
        else { return nil }
        return sampleBuffer
    }

    @Test("源格式 ≠ 目标格式时重采样：48k 单声道 → 44.1k 双声道")
    func convertedResamples() {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        )!
        let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 480)!
        source.frameLength = 480
        if let channelData = source.floatChannelData {
            for i in 0..<480 { channelData[0][i] = 0.4 }
        }
        let converter = AVAudioConverter(from: sourceFormat, to: RecordingAudioFormat.format)!

        let out = AudioSampleBufferFactory.converted(source, from: sourceFormat, using: converter)
        #expect(out != nil)
        // 480 @48k ≈ 441 @44.1k（允许重采样器的一点点缓冲差）。
        let frames = Int(out!.frameLength)
        #expect(frames >= 400 && frames <= 480)
        #expect(out!.format.channelCount == RecordingAudioFormat.channels)
        #expect(sample(out!, 0) > 0.2)
    }

    @Test("格式已是目标格式时 converted 原样返回，不做无谓的重采样")
    func convertedPassesThroughWhenFormatMatches() {
        let source = makeBuffer(frames: 16, value: 0.1)
        let converter = AVAudioConverter(
            from: RecordingAudioFormat.format, to: RecordingAudioFormat.format
        )!
        let out = AudioSampleBufferFactory.converted(
            source, from: RecordingAudioFormat.format, using: converter
        )
        #expect(out === source)
    }
}
