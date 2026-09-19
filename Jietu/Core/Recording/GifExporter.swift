import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// mp4 → GIF 导出：`AVAssetReader` 逐帧解码（顺带缩到目标宽度）→ `ImageIO` 编码。
///
/// 几个刻意的取舍：
/// - **10fps 是默认**：GIF 的每帧停留时间以 10ms 计数，10fps 的 0.1s 正好落在精度上，
///   不会有累计漂移；再高只是把体积堆上去（截图内容本来也没多少运动）。
/// - **限 60 秒**：GIF 体积随帧数线性涨，几分钟的录屏转出来是几十上百 MB，
///   与其让用户等一个没法用的文件，不如只导出开头这段（调用方在界面上说明）。
/// - **不放大**：源视频比目标宽度还窄时就按原宽度出，不做插值放大。
///
/// @author ixxxxoooo
nonisolated enum GifExporter {
    struct Configuration {
        /// 目标宽度（像素）；高度按比例算，取偶。
        var width: Int = 480
        /// 目标帧率（按下采样）。
        var fps: Int = 10
        /// 最长导出时长（秒），超出部分截断。
        var maximumDuration: TimeInterval = 60
    }

    nonisolated enum Failure: LocalizedError {
        case noVideoTrack
        case reader(String)
        case noFrames
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "这个文件里没有视频轨，转不了 GIF。"
            case .reader(let reason): return "读视频失败：\(reason)"
            case .noFrames: return "一帧都没解出来，转不了 GIF。"
            case .encodeFailed: return "GIF 编码失败（磁盘写满或没有写入权限）。"
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
        let size = outputSize(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            targetWidth: configuration.width
        )

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure.reader(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.reader("解不了视频轨") }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.reader(reader.error?.localizedDescription ?? "读不了这个文件")
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
        let context = CIContext(options: colorSpace.map { [.workingColorSpace: $0] } ?? [:])
        let step = step(sourceFps: sourceFps, targetFps: configuration.fps)
        let delay = frameDelay(for: configuration.fps)
        let limit = max(0.01, min(configuration.maximumDuration, CMTimeGetSeconds(duration)))
        var index = 0
        var written = 0
        while let sample = output.copyNextSampleBuffer() {
            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if seconds > limit { break }
            defer { index += 1 }
            guard index % step == 0, let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
            else { continue }
            guard let frame = resize(pixelBuffer, to: size, context: context) else { continue }
            CGImageDestinationAddImage(
                destinationRef, frame,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
                    as CFDictionary
            )
            written += 1
            if written % 8 == 0 { progress?(min(1, seconds / limit)) }
        }
        if reader.status == .failed {
            throw Failure.reader(reader.error?.localizedDescription ?? "解码中断")
        }
        guard written > 0 else { throw Failure.noFrames }
        guard CGImageDestinationFinalize(destinationRef) else { throw Failure.encodeFailed }
        succeeded = true
        progress?(1)
    }

    /// 取出这一帧的 CGImage。解码器多半已经缩到目标尺寸；没缩的（个别解码器忽略
    /// 输出尺寸）在这里用 CoreImage 补一刀，保证 GIF 尺寸就是我们承诺的那个。
    private static func resize(
        _ pixelBuffer: CVPixelBuffer, to size: (width: Int, height: Int), context: CIContext
    ) -> CGImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        if Int(extent.width) != size.width || Int(extent.height) != size.height,
            extent.width > 0, extent.height > 0
        {
            image = image.transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(size.width) / extent.width,
                    y: CGFloat(size.height) / extent.height
                )
            )
        }
        return context.createCGImage(image, from: image.extent)
    }
}
