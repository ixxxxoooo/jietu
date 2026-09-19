import Accelerate
import CoreMedia

/// 单队列轻量混音器：把系统声（`.audio`）与麦克风（`.microphone`）两路 Float32 PCM 实时相加。
///
/// 仅在两路**同时**开启时使用；单路时直写 Writer，不经过此类。
/// 所有方法均在 `RecordingEngine.queue`（串行）上调用——同队列无并发，无需锁。
///
/// @author ygw
nonisolated final class AudioStreamMixer: @unchecked Sendable {

    /// 等待配对的系统声样本。
    private var pendingSystem: CMSampleBuffer?
    /// 等待配对的麦克风样本。
    private var pendingMic: CMSampleBuffer?

    // MARK: - 外部接口

    /// 投入一份系统声样本。如果已有麦克风样本配对，返回混合结果；否则暂存、返回 nil。
    func addSystem(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        if let mic = pendingMic {
            pendingMic = nil
            return mixBuffers(buffer, mic)
        }
        pendingSystem = buffer
        return nil
    }

    /// 投入一份麦克风样本。如果已有系统声样本配对，返回混合结果；否则暂存、返回 nil。
    func addMic(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        if let sys = pendingSystem {
            pendingSystem = nil
            return mixBuffers(sys, buffer)
        }
        pendingMic = buffer
        return nil
    }

    /// 录制结束时排出剩余未配对的样本（单路尾巴），返回 nil 表示没有剩余。
    func flush() -> CMSampleBuffer? {
        let remaining = pendingSystem ?? pendingMic
        pendingSystem = nil
        pendingMic = nil
        return remaining
    }

    // MARK: - PCM 混音

    /// 把两份 Float32 PCM 样本逐采样相加（等功率衰减 ×0.707 ≈ −3 dB 防削波），
    /// 用第一份的时间戳和格式描述构造输出。
    private func mixBuffers(_ a: CMSampleBuffer, _ b: CMSampleBuffer) -> CMSampleBuffer? {
        guard let blockA = CMSampleBufferGetDataBuffer(a),
              let blockB = CMSampleBufferGetDataBuffer(b) else {
            return a
        }

        var lenA = 0, lenB = 0
        var ptrA: UnsafeMutablePointer<Int8>?
        var ptrB: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockA, atOffset: 0, lengthAtOffsetOut: nil,
                                     totalLengthOut: &lenA, dataPointerOut: &ptrA)
        CMBlockBufferGetDataPointer(blockB, atOffset: 0, lengthAtOffsetOut: nil,
                                     totalLengthOut: &lenB, dataPointerOut: &ptrB)
        guard let rawA = ptrA, let rawB = ptrB else { return a }

        let bytes = min(lenA, lenB)
        let floatCount = bytes / MemoryLayout<Float>.size
        guard floatCount > 0 else { return a }

        // vDSP 加法
        var mixed = [Float](repeating: 0, count: floatCount)
        rawA.withMemoryRebound(to: Float.self, capacity: floatCount) { aF in
            rawB.withMemoryRebound(to: Float.self, capacity: floatCount) { bF in
                vDSP_vadd(aF, 1, bF, 1, &mixed, 1, vDSP_Length(floatCount))
            }
        }
        // 等功率衰减（两路叠加后削波概率大，先衰 3 dB）
        var scale: Float = 0.707
        vDSP_vsmul(mixed, 1, &scale, &mixed, 1, vDSP_Length(floatCount))

        // 用 a 的格式 + 时间戳构造新 CMSampleBuffer
        guard let fmt = CMSampleBufferGetFormatDescription(a) else { return a }

        var outBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: 0, blockBufferOut: &outBlock) == noErr,
              let block = outBlock else {
            return a
        }

        guard CMBlockBufferReplaceDataBytes(
            with: &mixed, blockBuffer: block,
            offsetIntoDestination: 0, dataLength: bytes) == noErr else {
            return a
        }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(a),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(a),
            decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleCount: CMSampleBufferGetNumSamples(a),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &out)
        return out ?? a
    }
}
