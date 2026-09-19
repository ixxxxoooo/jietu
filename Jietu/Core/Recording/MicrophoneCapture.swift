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
nonisolated final class MicrophoneCapture: @unchecked Sendable {
    /// 采集链路的失败原因（调用方据此决定降级并提示用户）。
    nonisolated enum Failure: LocalizedError {
        case notAuthorized
        case noInputDevice
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "没有麦克风权限。"
            case .noInputDevice: return "找不到可用的输入设备。"
            case .unsupportedFormat: return "麦克风的音频格式转不了。"
            }
        }
    }

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

    /// 启动采集。失败（没授权 / 没有输入设备 / 格式转不了）抛错，调用方降级成无麦克风继续录。
    func start() throws {
        // 先过权限再碰 `inputNode`：没授权时访问输入节点本身就可能是崩溃/异常的来源。
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Failure.notAuthorized
        }
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw Failure.noInputDevice
        }

        // **tap 必须用硬件格式**：传一个与硬件不一致的 format，`installTap` 会抛 ObjC 异常
        // 直接终止进程（实测用户这台机器的麦克风是 48kHz 单声道，而我们要写 44.1kHz 双声道：
        // `Failed to create tap due to format mismatch`，且没有任何崩溃报告）。
        // 转换交给 `AVAudioConverter`，在下面这个 Sendable 盒子里做。
        guard
            let conversion = ConversionBox(source: hardware, target: RecordingAudioFormat.format)
        else { throw Failure.unsupportedFormat }

        input.installTap(
            onBus: 0, bufferSize: 4096, format: hardware
        ) { @Sendable [weak self] buffer, time in
            guard let self, let onBuffer = self.onBuffer, buffer.frameLength > 0 else { return }
            guard let converted = conversion.convert(buffer) else { return }
            onBuffer(converted, Self.timestamp(from: time))
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

/// tap 回调的转换状态：硬件格式 → 目标格式。
///
/// `AVAudioConverter` 不是 `Sendable`，而 tap 回调必须标 `@Sendable`（否则闭包继承
/// MainActor 隔离、被调到音频线程时触发隔离断言 trap）。用这个盒子把它装起来；
/// 同一 bus 的 tap 回调是**串行**的，所以转换器可以复用。
///
/// @author ixxxxoooo
private nonisolated final class ConversionBox: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let source: AVAudioFormat

    /// 源格式与目标格式一致时不需要转换；转不了（采样率/声道数不受支持）返回 nil。
    init?(source: AVAudioFormat, target: AVAudioFormat) {
        self.source = source
        if source == target {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
            self.converter = converter
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        return AudioSampleBufferFactory.converted(buffer, from: source, using: converter)
    }
}
