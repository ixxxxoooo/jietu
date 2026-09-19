import AVFoundation
import Accelerate
import Foundation

/// 录屏音频的公共目标格式：44.1kHz / 双声道 / Float32 **非交织**。
///
/// 系统声音（SCK 交付的 CMSampleBuffer）与麦克风（AVAudioEngine tap 出的 AVAudioPCMBuffer）
/// 都先归一到这里，混音与写轨才有同一套坐标。
///
/// @author ixxxxoooo
nonisolated enum RecordingAudioFormat {
    static let sampleRate: Double = 44_100
    static let channels: AVAudioChannelCount = 2
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: channels, interleaved: false
    )!
}

/// 双路实时混音器：系统声音 + 麦克风 → 一条 Float32 轨。
///
/// 为什么不直接写两条音轨：mp4 里放两条 audio track，播放器只出第一条，另一条等于丢了；
/// 所以必须在写入前按采样混成一路。
///
/// 排空节奏：哪个源来一拍就 `drain(until:)` 到那一拍的结尾——正常时系统声音按 ~20ms
/// 一拍推着走，麦克风跟着补位；就算系统声停了（静音 / 流断了），麦克风那一拍自己也能推进。
/// 时间轴以**帧序号**记账（timescale = 采样率），暂停回退由写入方兜底（见 `rewindIfNeeded`）。
///
/// 线程：系统声在采集队列上 append，麦克风在引擎的 tap 线程上 append，全部走 `lock`。
///
/// @author ixxxxoooo
nonisolated final class RealtimeAudioMixer {
    enum Source: Hashable, CaseIterable { case system, microphone }

    /// 单块混合输出的帧数（~93ms @44.1k，与 mic tap 的节奏同量级）。
    static let chunkFrames = 4096

    private let lock = NSLock()
    private var queues: [Source: [(pts: CMTime, buffer: AVAudioPCMBuffer)]] = [:]
    /// 已经输出到的位置（目标时间轴的帧序号）。
    private var emittedFrames: Int64 = 0
    private var hasEmitted = false
    /// 因迟到被丢掉的采样帧数（诊断用：正常应接近 0）。
    private(set) var droppedLateFrames: Int64 = 0

    /// 追加一路采样。`pts` 必须是**目标时间轴**上的（写入方已做暂停前移）。
    func enqueue(_ source: Source, buffer: AVAudioPCMBuffer, at pts: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        rewindIfNeeded(at: pts)
        queues[source, default: []].append((pts, buffer))
    }

    /// 排空到 `endTime`（含）：把 `[已输出位置, endTime]` 按 `chunkFrames` 切块产出。
    /// 只有单一源覆盖的区间照原样输出（另一路补静音），重叠区间按采样相加。
    func drain(until endTime: CMTime) -> [(pts: CMTime, buffer: AVAudioPCMBuffer)] {
        lock.lock()
        defer { lock.unlock() }
        rewindIfNeeded(at: endTime)
        let endFrames = Self.frameIndex(of: endTime)
        guard endFrames > emittedFrames else { return [] }
        if !hasEmitted {
            // 第一拍：从两路里最早的一帧起步（早于它的迟到采样会被当成 late 丢掉）。
            emittedFrames = initialEmittedFrames(endFrames: endFrames)
            hasEmitted = true
        }

        var output: [(pts: CMTime, buffer: AVAudioPCMBuffer)] = []
        let timescale = CMTimeScale(RecordingAudioFormat.sampleRate)
        while emittedFrames < endFrames {
            let count = Int(min(Int64(Self.chunkFrames), endFrames - emittedFrames))
            guard
                let chunk = AVAudioPCMBuffer(
                    pcmFormat: RecordingAudioFormat.format, frameCapacity: AVAudioFrameCount(count)
                )
            else { break }
            chunk.frameLength = AVAudioFrameCount(count)
            mix(into: chunk, covering: emittedFrames, count: count)
            output.append((CMTime(value: emittedFrames, timescale: timescale), chunk))
            emittedFrames += Int64(count)
        }
        return output
    }

    /// 第一拍初始化 `emittedFrames`：取所有在排采样的最早帧号，夹在 `[0, endFrames]`。
    ///（正常 ≥ 0；暂停回退后清空重来时，endFrames 会落在最早帧之前，需要夹住。）
    private func initialEmittedFrames(endFrames: Int64) -> Int64 {
        let earliest = queues.values.flatMap { $0 }.map { Self.frameIndex(of: $0.pts) }.min()
        return min(max(earliest ?? endFrames, 0), endFrames)
    }

    /// 暂停恢复后时间轴会整体前移（写入方的 `adjusted`）——挡到「新采样比已输出位置
    /// 还早半个多秒」就视为回退，清空重来，否则混音窗口会卡死在过去。
    private func rewindIfNeeded(at pts: CMTime) {
        guard hasEmitted else { return }
        let index = Self.frameIndex(of: pts)
        if index < emittedFrames - Int64(RecordingAudioFormat.sampleRate / 2) {
            queues.removeAll()
            hasEmitted = false
            // 「已输出位置」直接作废成 0：回退后的采样是负帧号，
            // 清零才能让 `drain` 的 guard 放行、下一拍从最早的回退帧重新起步。
            emittedFrames = 0
        }
    }

    /// 把两路在这块窗口里的采样混进 `chunk`（有采样相加，没有就是静音底），
    /// 顺手清掉完全落在窗口之前的迟到采样。
    private func mix(into chunk: AVAudioPCMBuffer, covering start: Int64, count: Int) {
        let end = start + Int64(count)
        guard let out = chunk.floatChannelData else { return }
        for channel in 0..<Int(RecordingAudioFormat.channels) {
            memset(out[channel], 0, count * MemoryLayout<Float>.size)
        }
        for source in Source.allCases {
            guard var queue = queues[source] else { continue }
            var kept: [(pts: CMTime, buffer: AVAudioPCMBuffer)] = []
            for entry in queue {
                let entryStart = Self.frameIndex(of: entry.pts)
                let entryFrames = Int64(entry.buffer.frameLength)
                let entryEnd = entryStart + entryFrames
                if entryEnd <= start {
                    droppedLateFrames += entryFrames
                    continue
                }
                if entryEnd <= end {
                    mixEntry(entry, from: entryStart, into: chunk, windowStart: start, count: count)
                    continue
                }
                // 跨窗口：混进本窗口它覆盖的那段，整条留到下一窗口再清。
                mixEntry(entry, from: entryStart, into: chunk, windowStart: start, count: count)
                kept.append(entry)
            }
            queues[source] = kept.isEmpty ? nil : kept
        }
    }

    private func mixEntry(
        _ entry: (pts: CMTime, buffer: AVAudioPCMBuffer), from entryStart: Int64,
        into chunk: AVAudioPCMBuffer,
        windowStart: Int64, count: Int
    ) {
        guard
            let src = entry.buffer.floatChannelData,
            let out = chunk.floatChannelData
        else { return }
        let offset = max(0, windowStart - entryStart)
        let srcFrames = Int64(entry.buffer.frameLength) - offset
        let skip = Int(max(0, entryStart - windowStart))
        // ⚠️ 关键修正：`usable` 必须夹在 `count - skip` 以内——
        // 老公式 `count - (entryStart - windowStart)` 当 entryStart < windowStart 时
        // 会产生大于 count 的值，写越界导致杂音 / 爆音。
        let usable = Int(min(srcFrames, Int64(count - skip)))
        guard usable > 0 else { return }
        for channel in 0..<Int(RecordingAudioFormat.channels) {
            let source = src[channel].advanced(by: Int(offset))
            let target = out[channel].advanced(by: skip)
            // vDSP 向量加法：比逐样本循环快几倍，音频线程上更不易卡。
            vDSP_vadd(source, 1, target, 1, target, 1, vDSP_Length(usable))
        }
    }

    private static func frameIndex(of time: CMTime) -> Int64 {
        let index = Int64((CMTimeGetSeconds(time) * RecordingAudioFormat.sampleRate).rounded())
        return max(0, index)
    }
}

/// CMSampleBuffer ↔ AVAudioPCMBuffer 的互转，外加「按需重采样」。
///
/// SCK 交付的系统声格式以它自己声明的 ASBD 为准（我们配置了 44.1k/2ch，但不空口假设），
/// 先原样解成 PCMBuffer，格式对不上目标格式时再用 AVAudioConverter 转一次。
///
/// @author ixxxxoooo
nonisolated enum AudioSampleBufferFactory {
    /// 目标格式的格式描述（不可变，进程级缓存一份）。
    private static let formatDescription: CMFormatDescription? = {
        var description: CMFormatDescription?
        let asbd = RecordingAudioFormat.format.streamDescription
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description
        )
        return description
    }()

    /// 把 PCMBuffer 打包成 CMSampleBuffer（非交织：声道 0、1 各一段连续内存，先 0 后 1）。
    /// 产物是写给 `AVAssetWriterInput` 的（AAC 输入自己做交织转换）；
    /// 要转回 PCMBuffer 请走 `converted`（非交织格式喂不进
    /// `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` 的 bufferList）。
    static func sampleBuffer(
        from buffer: AVAudioPCMBuffer, at pts: CMTime
    ) -> CMSampleBuffer? {
        guard let description = formatDescription, buffer.frameLength > 0 else { return nil }
        guard let channelData = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let bytesPerFrame = MemoryLayout<Float>.size
        let totalBytes = frames * bytesPerFrame * Int(RecordingAudioFormat.channels)

        var blockBuffer: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: totalBytes,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: totalBytes, flags: 0, blockBufferOut: &blockBuffer
            ) == kCMBlockBufferNoErr, let blockBuffer
        else { return nil }
        for channel in 0..<Int(RecordingAudioFormat.channels) {
            guard
                CMBlockBufferReplaceDataBytes(
                    with: channelData[channel], blockBuffer: blockBuffer,
                    offsetIntoDestination: channel * frames * bytesPerFrame,
                    dataLength: frames * bytesPerFrame
                ) == kCMBlockBufferNoErr
            else { return nil }
        }

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

    /// 把 SCK 交付的音频 CMSampleBuffer 解成 PCMBuffer（保留**它自己的**格式）。
    ///
    /// 源数据先落到我们自己分配的 AudioBufferList 里，再按源格式是否**交织**拷进 pcm：
    /// 交织是一段 LRLR…（要拆声道），非交织是一声道一段。直接把源 list 塞进
    /// `pcm.mutableAudioBufferList` 是不行的——那只按 pcm 自己的格式分配大小。
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
            let sourceFormat = AVAudioFormat(streamDescription: &asbd)
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else { return nil }
        pcm.frameLength = frames

        // 源 list 的容量按**源格式**算：交织格式只有 1 个 AudioBuffer，非交织才是一声道一个。
        let bufferCount = sourceFormat.isInterleaved ? 1 : Int(sourceFormat.channelCount)
        let listSize = MemoryLayout<AudioBufferList>.size
            + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let sourceList = raw.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: sourceList, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let channels = pcm.floatChannelData else { return nil }

        let channelCount = Int(sourceFormat.channelCount)
        if sourceFormat.isInterleaved {
            guard let source = sourceList.pointee.mBuffers.mData?
                .assumingMemoryBound(to: Float.self)
            else { return nil }
            for frame in 0..<Int(frames) {
                for channel in 0..<channelCount {
                    channels[channel][frame] = source[frame * channelCount + channel]
                }
            }
        } else {
            let list = UnsafeMutableAudioBufferListPointer(sourceList)
            for channel in 0..<min(channelCount, list.count) {
                guard let data = list[channel].mData else { continue }
                memcpy(channels[channel], data, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        return pcm
    }

    /// 源格式 ≠ 目标格式时重采样（converter 由调用方持有并复用）。
    static func converted(
        _ buffer: AVAudioPCMBuffer, from source: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        guard source != RecordingAudioFormat.format else { return buffer }
        let ratio = RecordingAudioFormat.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: RecordingAudioFormat.format, frameCapacity: capacity
            )
        else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0,
            status == .haveData || status == .inputRanDry
        else { return nil }
        return output
    }
}
