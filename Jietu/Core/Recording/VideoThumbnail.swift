import AVFoundation
import CoreGraphics
import Foundation

/// 从录好的 mp4 里取一张封面帧 + 读真实时长（浮窗视频卡要用）。
///
/// 封面取 **0.1 秒**那一帧而不是第 0 帧：刚开录的第一帧经常是黑场（流还没画上去），
/// 整张卡会是一块黑。成片极短（<0.2s）时退到中点。
///
/// @author ixxxxoooo
enum VideoThumbnail {
    /// 封面帧 + 时长。读不出来返回 nil（调用方退回「只有通知」那条路，别把收工搞挂）。
    static func make(for url: URL) async -> (image: CGImage, duration: TimeInterval)? {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let duration = seconds.isFinite && seconds > 0 ? seconds : 0

        let generator = AVAssetImageGenerator(asset: asset)
        // 录屏是屏幕内容：不做「首选变换」的话竖屏录制会躺倒。
        generator.appliesPreferredTrackTransform = true
        // 卡片最大才 260×180 点，别为了封面解码一整张 4K 帧。
        generator.maximumSize = CGSize(width: 520, height: 520)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let time = CMTime(seconds: duration > 0.2 ? 0.1 : duration / 2, preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        return (image, duration)
    }
}
