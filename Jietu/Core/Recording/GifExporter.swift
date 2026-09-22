import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// mp4 → GIF 导出：`AVAssetReader` 逐帧解码 → CoreImage 高品质抗锯齿下采样与阶调调优 → `ImageIO` 编码。
///
/// 几个刻意的取舍：
/// - **15fps 是默认**：在画面流畅度（无指针瞬移感）与文件体积之间取得业界公认最佳平衡；
///   亦支持 10fps（体积优先）、24fps / 30fps（高帧率动效）。
/// - **视网膜屏 1x 推荐（50%）**：将 Retina 2x 屏幕物理像素精准对应为 1x 逻辑像素，
///   文字纤细锐利、不模糊，且比 100% 原始尺寸节省约 75% 体积。
/// - **高品质下采样**：采用 CoreImage 区域平均 Lanczos 抗锯齿下采样，规避解码器硬件插值的发虚模糊。
/// - **双时钟标记**：同时写入 `kCGImagePropertyGIFDelayTime` 与 `kCGImagePropertyGIFUnclampedDelayTime`，
///   解决部分浏览器和系统播放器对 <100ms 帧延时的粗暴钳制。
/// - **限 60 秒**：GIF 体积随帧数线性涨，几分钟的录屏转出来是几十上百 MB，
///   与其让用户等一个没法用的文件，不如只导出开头这段。
/// - **不放大**：源视频比目标尺寸还小时按原宽出，不做插值虚化放大。
///
/// @author ixxxxoooo
nonisolated enum GifExporter {
    struct Configuration {
        /// 自定义宽度（像素）；指定后优先于 resolution，用于向前兼容与自测。
        var width: Int?
        /// 分辨率/尺寸偏好。
        var resolution: GifResolution
        /// 目标帧率（按下采样）。
        var fps: Int
        /// 画质偏好。
        var quality: GifQuality
        /// 最长导出时长（秒），超出部分截断。
        var maximumDuration: TimeInterval

        init(
            width: Int? = nil,
            resolution: GifResolution = .retina1x,
            fps: Int = 15,
            quality: GifQuality = .high,
            maximumDuration: TimeInterval = 60
        ) {
            self.width = width
            self.resolution = resolution
            self.fps = fps
            self.quality = quality
            self.maximumDuration = maximumDuration
        }
    }

    nonisolated enum Failure: LocalizedError {
        case noVideoTrack
        case reader(String)
        case noFrames
        case encodeFailed

        fileprivate static func _l(_ key: String) -> String {
            let result = CFBundleCopyLocalizedString(
                CFBundleGetMainBundle(), key as CFString, key as CFString, "Localizable" as CFString
            )
            return result as String? ?? key
        }

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return Self._l("gif_error.no_video_track")
            case .reader(let reason): return String(format: Self._l("gif_error.reader"), reason)
            case .noFrames: return Self._l("gif_error.no_frames")
            case .encodeFailed: return Self._l("gif_error.encode_failed")
            }
        }
    }

    // MARK: - 纯函数（单测直接钉）

    /// 源帧率 → 采样步长（每 `step` 帧取一帧）。
    static func step(sourceFps: Double, targetFps: Int) -> Int {
        guard sourceFps > 0, targetFps > 0 else { return 1 }
        return max(1, Int((sourceFps / Double(targetFps)).rounded()))
    }

    /// 每帧停留秒数，按 GIF 的 10ms 精度取整。
    static func frameDelay(for targetFps: Int) -> Double {
        guard targetFps > 0 else { return 0.1 }
        return (100.0 / Double(targetFps)).rounded() / 100
    }

    /// 输出尺寸：等比缩到目标宽度、取偶、**不放大**。
    static func outputSize(
        sourceWidth: Int, sourceHeight: Int, targetWidth: Int
    ) -> (width: Int, height: Int) {
        let width = max(2, sourceWidth)
        let height = max(2, sourceHeight)
        let scale = min(1, Double(max(2, targetWidth)) / Double(width))
        return VideoEncodingSettings.evenDimensions(
            width: Int((Double(width) * scale).rounded()),
            height: Int((Double(height) * scale).rounded())
        )
    }

    // MARK: - 导出

    /// 导出 GIF。`progress` 回调在**后台线程**上（0...1），界面侧自己跳主线程。
    static func export(
        from sourceURL: URL,
        to destination: URL,
        configuration: Configuration = Configuration(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await Task.detached(priority: .utility) {
            try await run(
                from: sourceURL, to: destination,
                configuration: configuration, progress: progress
            )
        }.value
    }

    private static func run(
        from sourceURL: URL,
        to destination: URL,
        configuration: Configuration,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        var succeeded = false
        defer {
            // 半成品不留在磁盘上（失败时用户看到的就是「没导出」）。
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let nominalSize = try await track.load(.naturalSize)
        var sourceWidth = Int(nominalSize.width.rounded())
        var sourceHeight = Int(nominalSize.height.rounded())
        if sourceWidth <= 0 || sourceHeight <= 0 {
            // 少数封装里 naturalSize 是 0：退回视频轨自己的格式描述取尺寸。
            let descriptions = try await track.load(.formatDescriptions)
            if let description = descriptions.first {
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                sourceWidth = Int(dimensions.width)
                sourceHeight = Int(dimensions.height)
            }
        }
        let sourceFps = Double(try await track.load(.nominalFrameRate))
        let size: (width: Int, height: Int)
        if let customWidth = configuration.width {
            size = outputSize(
                sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                targetWidth: customWidth
            )
        } else {
            size = configuration.resolution.calculateSize(
                sourceWidth: sourceWidth, sourceHeight: sourceHeight
            )
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure.reader(error.localizedDescription)
        }
        // 解码端不预先强制缩放，保留全分辨率原图交给 CoreImage 抗锯齿管线，杜绝解码器硬件插值发虚
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.reader(Failure._l("gif_error.cannot_add_track")) }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.reader(reader.error?.localizedDescription ?? Failure._l("gif_error.cannot_read_file"))
        }

        guard
            let destinationRef = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.gif.identifier as CFString, 0, nil
            )
        else { throw Failure.encodeFailed }
        CGImageDestinationSetProperties(
            destinationRef,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        )

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        var ciOptions: [CIContextOption: Any] = [
            .highQualityDownsample: true
        ]
        if let colorSpace {
            ciOptions[.workingColorSpace] = colorSpace
        }
        let context = CIContext(options: ciOptions)
        let step = step(sourceFps: sourceFps, targetFps: configuration.fps)
        let delay = frameDelay(for: configuration.fps)
        let limit = max(0.01, min(configuration.maximumDuration, CMTimeGetSeconds(duration)))
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]
        ]
        var index = 0
        var written = 0
        while let sample = output.copyNextSampleBuffer() {
            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if seconds > limit { break }
            defer { index += 1 }
            guard index % step == 0, let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
            else { continue }
            let frameWritten: Bool = autoreleasepool {
                guard let frame = resize(
                    pixelBuffer, to: size, quality: configuration.quality, context: context
                ) else { return false }
                CGImageDestinationAddImage(
                    destinationRef, frame, frameProperties as CFDictionary
                )
                return true
            }
            if frameWritten {
                written += 1
                if written % 8 == 0 { progress?(min(1, seconds / limit)) }
            }
        }
        if reader.status == .failed {
            throw Failure.reader(reader.error?.localizedDescription ?? Failure._l("gif_error.decoding_interrupted"))
        }
        guard written > 0 else { throw Failure.noFrames }
        guard CGImageDestinationFinalize(destinationRef) else { throw Failure.encodeFailed }
        succeeded = true
        progress?(1)
    }

    /// 高保真处理每一帧：高质量抗锯齿下采样与画质阶调调优。
    private static func resize(
        _ pixelBuffer: CVPixelBuffer,
        to size: (width: Int, height: Int),
        quality: GifQuality,
        context: CIContext
    ) -> CGImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        if Int(extent.width) != size.width || Int(extent.height) != size.height {
            let scaleX = CGFloat(size.width) / extent.width
            let scaleY = CGFloat(size.height) / extent.height
            // 高品质抗锯齿下采样：保留文本与 UI 边缘的高频细节
            image = image.transformed(
                by: CGAffineTransform(scaleX: scaleX, y: scaleY),
                highQualityDownsample: true
            )
        }

        switch quality {
        case .high:
            break
        case .medium:
            // 平衡模式：32 阶色彩调优，抹平视频压缩底噪，大幅缩小 GIF 尺寸且 UI 无感知
            if let filter = CIFilter(name: "CIColorPosterize") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(32.0, forKey: "inputLevels")
                if let out = filter.outputImage { image = out }
            }
        case .low:
            // 压缩优先：16 阶色彩，动图体积减半，适合聊天应用或邮件即时分享
            if let filter = CIFilter(name: "CIColorPosterize") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(16.0, forKey: "inputLevels")
                if let out = filter.outputImage { image = out }
            }
        }

        return context.createCGImage(
            image,
            from: CGRect(x: 0, y: 0, width: size.width, height: size.height)
        )
    }
}
