import AVFoundation
import AppKit
import CoreGraphics
import ImageIO

#if DEBUG

/// 成片再加工的自检：造一段合成视频 → 走**真实**的 GIF 导出 → 读回产物校验。
///
/// 单测只能钉纯函数（尺寸 / 步长），解码 + 编码这条链路必须在真环境里跑一遍——
/// GIF 编不出来只有跑起来才知道。裁剪功能已去掉（macOS 预览 App 自带）。
///
///   Jietu --selftest-video-tools <输出目录>
///
/// @author ixxxxoooo
enum VideoToolsSelfTest {

    static func run(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            var failures = 0
            func check(_ condition: Bool, _ ok: String, _ bad: String) {
                if condition {
                    report.append("✓ \(ok)")
                } else {
                    report.append("✗ \(bad)")
                    failures += 1
                }
            }

            do {
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                // ① 造源视频：2 秒 / 30fps / 320×240（纯合成，不依赖屏幕录制权限）。
                report.append("== 源视频 ==")
                let source = outputDirectory.appendingPathComponent("video-tools-source.mp4")
                try? FileManager.default.removeItem(at: source)
                let frames = try await makeTestVideo(
                    at: source, seconds: 2, fps: 30, size: CGSize(width: 320, height: 240)
                )
                let sourceDuration = CMTimeGetSeconds(
                    try await AVURLAsset(url: source).load(.duration)
                )
                report.append(
                    "\(frames) 帧 / \(String(format: "%.2f", sourceDuration))s / "
                        + "\(fileSize(source)) —— \(source.path)"
                )

                // ② GIF：期望 160 宽（≤ 源宽，不放大）、帧数与时长都对得上。
                report.append("")
                report.append("== GIF 导出 ==")
                let gif = outputDirectory.appendingPathComponent("video-tools.gif")
                try? FileManager.default.removeItem(at: gif)
                var progressSeen: [Double] = []
                let recorder = ProgressRecorder()
                try await GifExporter.export(
                    from: source, to: gif,
                    configuration: GifExporter.Configuration(width: 160, fps: 10)
                ) { fraction in
                    recorder.record(fraction)
                }
                progressSeen = recorder.values
                let gifFrames = gifFrameCount(gif)
                let gifSize = gifPixelSize(gif)
                report.append(
                    "\(gifFrames) 帧 / \(gifSize?.width ?? 0)×\(gifSize?.height ?? 0) / "
                        + "\(fileSize(gif)) —— \(gif.path)"
                )
                check(FileManager.default.fileExists(atPath: gif.path), "GIF 落盘了", "GIF 没生成")
                check(gifFrames >= 15 && gifFrames <= 25, "帧数 ≈ 2s × 10fps（实测 \(gifFrames)）",
                      "帧数不对：\(gifFrames)")
                check(gifSize?.width == 160 && gifSize?.height == 120,
                      "尺寸按 160 宽等比（160×120）",
                      "尺寸不对：\(String(describing: gifSize))")
                check(progressSeen.last == 1.0, "进度回调走到 100%", "进度没走完：\(progressSeen.last ?? -1)")

                report.append("")
                report.append(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL（\(failures) 项）")
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                failures += 1
            }
            CaptureSelfTest.finish(report, code: failures == 0 ? 0 : 1)
        }
    }

    // MARK: - 造源视频

    /// 逐帧画色块（帧号驱动颜色 + 一个扫过的白方块），H.264 / mp4 / 无音轨。
    ///
    /// 对其它自检开放（app 级裁剪自检也用它造源文件）。
    static func makeTestVideo(
        at url: URL, seconds: Double, fps: Int, size: CGSize
    ) async throws -> Int {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: VideoEncodingSettings.outputSettings(
                width: Int(size.width), height: Int(size.height), fps: fps
            )
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        guard writer.canAdd(input) else {
            throw RecordingEngine.Failure.startFailed("自检视频轨加不进去")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecordingEngine.Failure.startFailed("自检 startWriting 失败")
        }
        writer.startSession(atSourceTime: .zero)

        let total = max(1, Int(seconds * Double(fps)))
        for index in 0..<total {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let buffer = try makePixelBuffer(index: index, total: total, size: size)
            guard
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(
                        value: CMTimeValue(index), timescale: CMTimeScale(fps)
                    )
                )
            else {
                throw writer.error ?? RecordingEngine.Failure.startFailed("自检写帧失败")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? RecordingEngine.Failure.startFailed("自检 finishWriting 失败")
        }
        return total
    }

    private static func makePixelBuffer(
        index: Int, total: Int, size: CGSize
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw RecordingEngine.Failure.startFailed("自检造帧失败（\(status)）")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { throw RecordingEngine.Failure.startFailed("自检建绘图上下文失败") }

        let progress = Double(index) / Double(max(1, total - 1))
        context.setFillColor(
            CGColor(red: progress, green: 0.25, blue: 1 - progress, alpha: 1)
        )
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(
            CGRect(x: progress * (size.width - 48), y: size.height / 2 - 24, width: 48, height: 48)
        )
        return pixelBuffer
    }

    // MARK: - 读回校验

    private static func gifFrameCount(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    private static func gifPixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image.width, image.height)
    }

    private static func fileSize(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0
        return String(format: "%.0f KB", bytes / 1024)
    }
}

/// 进度回调（`@Sendable`，跑在后台线程）就地收值的小容器。
///
/// @author ixxxxoooo
private nonisolated final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

#endif
