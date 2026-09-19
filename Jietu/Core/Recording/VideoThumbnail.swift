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

    /// 为裁剪界面的电影胶片条批量取缩略图。
    ///
    /// 沿时间轴均匀取 `count` 帧，每帧缩到 `height` 高度（宽度按比例算）。
    /// 用 `AVAssetImageGenerator.images(for:)` 批量请求——引擎可以优化解码顺序，
    /// 比逐帧循环 `image(at:)` 快得多，20 帧 ~0.3 秒（SSD 上的典型录屏）。
    static func filmstrip(
        for url: URL, count: Int = 20, height: CGFloat = 50
    ) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration),
            CMTimeGetSeconds(seconds) > 0
        else { return [] }
        let total = CMTimeGetSeconds(seconds)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 高度 50pt × 2x = 100px，足够清晰而不会拖慢解码。
        generator.maximumSize = CGSize(width: height * 4, height: height * 2)
        // 允许一些容差：精确取帧很慢，这里只是缩略图不需要帧精确。
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let times = (0..<count).map { i in
            CMTime(
                seconds: total * Double(i) / Double(max(1, count - 1)),
                preferredTimescale: 600
            )
        }

        var images: [CGImage] = []
        do {
            for try await result in generator.images(for: times) {
                images.append(try result.image)
            }
        } catch {
            // 部分成功也返回——比起空条好得多。
        }
        return images
    }

    /// 取不到封面时的占位图（中性灰底）。
    ///
    /// 用途：录屏**必须**能进「最近记录」——封面只是好看，缺了它不能让整条记录消失
    /// （用户报的「录完东西不见了」正是因为历史里什么都没有）。
    static func placeholder(width: Int = 320, height: Int = 180) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.setFillColor(CGColor(gray: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
