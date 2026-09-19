import AVFoundation
import Foundation

/// 裁剪区间的纯逻辑：夹进时长、保序（start 比 end 大就换过来）、保最短长度。
///
/// @author ixxxxoooo
nonisolated enum TrimRange {
    /// 最短可导出长度（秒）。再短就没有「一段视频」的意思了，按误操作处理。
    static let minimumLength: TimeInterval = 0.1

    /// 归整成可用区间；比 `minimumLength` 还短返回 nil。
    static func clamp(
        start: TimeInterval, end: TimeInterval, duration: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval)? {
        let total = max(0, duration)
        var lower = min(max(0, start), total)
        var upper = min(max(0, end), total)
        if upper < lower { swap(&lower, &upper) }
        guard upper - lower >= minimumLength else { return nil }
        return (lower, upper)
    }
}

/// 成片裁剪：`AVAssetExportSession` **直通**导出（不重新编码，只搬需要的帧）。
///
/// 直通的好处是快——几分钟的录屏几乎瞬间完成；代价是裁剪点会对齐到最近的关键帧
/// （我们的录制每 ~1 秒一个 I 帧，所以误差在一秒以内）。对「掐头去尾」这种用法足够。
///
/// @author ixxxxoooo
nonisolated enum VideoTrimmer {
    nonisolated enum Failure: LocalizedError {
        /// 区间太短 / 时长为 0。
        case invalidRange
        case unsupported
        case export(String)

        var errorDescription: String? {
            switch self {
            case .invalidRange: return "这段区间太短了，至少留 0.1 秒。"
            case .unsupported: return "系统导不出这个格式。"
            case .export(let reason): return "导出失败：\(reason)"
            }
        }
    }

    /// 把 `[start, end]` 这一段另存到 `destination`。
    static func export(
        from sourceURL: URL, to destination: URL,
        start: TimeInterval, end: TimeInterval
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard let range = TrimRange.clamp(start: start, end: end, duration: duration) else {
            throw Failure.invalidRange
        }
        guard
            let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetPassthrough
            )
        else { throw Failure.unsupported }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            end: CMTime(seconds: range.end, preferredTimescale: 600)
        )
        session.outputFileType = .mp4
        // 保存面板已经确认过「替换」：这里先清掉同名文件，否则导出会直接失败。
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            try await session.export(to: destination, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.export(error.localizedDescription)
        }
    }
}
