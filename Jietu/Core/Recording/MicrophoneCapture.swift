import AVFoundation
import Foundation

/// 麦克风采集：`AVAudioEngine` 输入节点 tap，直接吐**目标格式**的 PCMBuffer
/// （44.1kHz / 双声道 / Float32，引擎自动完成从硬件格式的转换）。
///
/// 时间戳用 `AVAudioTime.hostTime` 换算成秒——mach 时间轴与 ScreenCaptureKit 的
/// PTS 同一纪元，混音对齐才有共同坐标。
///
/// tap 回调跑在引擎自己的线程上：闭包标 `@Sendable`，里面只许碰 nonisolated 的东西
/// （本模块默认 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不标会隔离断言 trap）。
///
/// @author ixxxxoooo
nonisolated final class MicrophoneCapture {
    /// 每拍一个 PCMBuffer + 它第一个采样的时间戳（mach 纪元的秒）。
    var onBuffer: (@Sendable (AVAudioPCMBuffer, CMTime) -> Void)?

    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    /// 系统设置里的麦克风隐私面板（通知点击时跳过去）。
    static var privacySettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    }

    /// 麦克风权限：现读，`notDetermined` 时弹系统授权。
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// 启动采集。失败（没有输入设备 / 引擎起不来）抛错，调用方决定降级成无麦克风继续录。
    func start() throws {
        let input = engine.inputNode
        input.installTap(
            onBus: 0, bufferSize: 4096, format: RecordingAudioFormat.format
        ) { [weak self] buffer, time in
            guard let self, let onBuffer = self.onBuffer, buffer.frameLength > 0 else { return }
            onBuffer(buffer, Self.timestamp(from: time))
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// 停止采集并摘掉 tap（必须在 writer finish 之前调，保证没有采样还在飞）。
    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// AVAudioTime → CMTime（hostTime 走 mach 时间基换算成秒）。
    private static func timestamp(from time: AVAudioTime) -> CMTime {
        guard time.isHostTimeValid else {
            return CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 44_100)
        }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let seconds = Double(time.hostTime) * Double(info.numer) / Double(info.denom) / 1e9
        return CMTime(seconds: seconds, preferredTimescale: 44_100)
    }
}
