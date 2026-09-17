import AVFoundation
import CoreGraphics
import Foundation

/// 录屏的编码参数（H.264 / mp4）。
///
/// 参考 capcap 的 `VideoEncodingSettings`：
/// - 码率按「像素数 × 帧率 × 系数」估，再按分辨率收一档，最后夹在 3Mbps ~ 80Mbps；
/// - 宽高**向上**取偶：直接 `/2*2` 会把 1921 截成 1920（少一列像素），
///   `(n+1)/2*2` 才是向上取到偶数；
/// - 关键帧间隔 = 帧率（≈1 秒一个 I 帧），拖进度条 / 转 GIF 都不至于糊。
///
/// 纯函数，单测直接钉数值。
///
/// @author ixxxxoooo
nonisolated enum VideoEncodingSettings {
    /// 码率的上下限（bps）。
    static let minimumBitrate = 3_000_000
    static let maximumBitrate = 80_000_000

    /// 向上取到偶数（至少 2）。
    static func even(_ value: Int) -> Int {
        max(2, ((max(1, value) + 1) / 2) * 2)
    }

    static func evenDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        (even(width), even(height))
    }

    /// 估算码率（bps）。
    ///
    /// 4K 以上收 20%、1080p 以上收 8%——高分辨率下按线性给码率会大得离谱，
    /// 而同等「每像素比特数」在高分辨率下观感其实更好。
    static func bitrate(width: Int, height: Int, fps: Int) -> Int {
        let pixels = Double(max(1, width)) * Double(max(1, height))
        let frameRate = Double(max(1, fps))
        var value = pixels * frameRate * 0.21
        if pixels > 3840 * 2160 {
            value *= 0.80
        } else if pixels > 1920 * 1080 {
            value *= 0.92
        }
        return Int(min(max(value, Double(minimumBitrate)), Double(maximumBitrate)).rounded())
    }

    /// `AVAssetWriterInput` 的输出参数（BT.709）。
    static func outputSettings(width: Int, height: Int, fps: Int) -> [String: Any] {
        let dimensions = evenDimensions(width: width, height: height)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate(
                width: dimensions.width, height: dimensions.height, fps: fps
            ),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: max(1, fps),
            // CABAC 比 CAVLC 省码率，录屏这种大片平坦区域的内容特别明显。
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
        ]
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    /// 系统音频的编码参数（AAC 立体声 44.1kHz）。
    static func systemAudioOutputSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 128_000,
        ]
    }
}
