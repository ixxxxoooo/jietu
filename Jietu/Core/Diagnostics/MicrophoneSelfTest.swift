import AVFoundation
import Foundation

#if DEBUG

/// 麦克风采集自检：真开一次输入设备，看硬件格式能不能被正确转成写入格式。
///
/// 存在的理由：`installTap` 的 format 一旦与硬件不一致就会**抛异常终止进程**
/// （实测用户的机器是 48kHz 单声道，而写入格式是 44.1kHz 双声道），
/// 这条链路只有真设备能验。
///
///   Jietu --selftest-microphone
///
/// @author ixxxxoooo
enum MicrophoneSelfTest {

    /// 分步痕迹：写文件而不是 stdout——这条检查常常要经 LaunchServices 启动才拿得到麦克风权限，
    /// 那种情况下 stdout 看不见，而且真崩了 `finish` 也不会执行。
    private static func trace(_ text: String) {
        let url = URL(fileURLWithPath: "/tmp/jietu-mic-trace.txt")
        let line = text + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func run() {
        Task { @MainActor in
            trace("run() 开始（进程 \(ProcessInfo.processInfo.processIdentifier)）")
            var report: [String] = []
            var failures = 0
            func check(_ ok: Bool, _ pass: String, _ fail: String) {
                report.append(ok ? "✓ \(pass)" : "✗ \(fail)")
                if !ok { failures += 1 }
            }

            trace("请求/读取麦克风权限…")
            let authorized = await MicrophoneCapture.requestPermission()
            trace("权限结果=\(authorized)")
            let permissionText = authorized ? "已授权" : "**没给**（系统设置里允许后重跑）"
            report.append("麦克风权限：\(permissionText)")
            guard authorized else {
                report.append("RESULT: FAIL（没权限，验不了采集）")
                CaptureSelfTest.finish(report, code: 1)
                return
            }

            // 先把硬件格式打出来：它就是「tap 必须用硬件格式」这条约束的现场。
            trace("查询硬件格式…")
            let probe = AVAudioEngine()
            let hardware = probe.inputNode.outputFormat(forBus: 0)
            trace("硬件格式=\(Int(hardware.sampleRate))Hz/\(hardware.channelCount)ch")
            report.append(
                "硬件格式：\(Int(hardware.sampleRate)) Hz / \(hardware.channelCount) ch；"
                    + "写入格式：\(Int(RecordingAudioFormat.sampleRate)) Hz / "
                    + "\(RecordingAudioFormat.channels) ch"
            )

            let recorder = SampleRecorder()
            let capture = MicrophoneCapture()
            capture.onBuffer = { @Sendable buffer, _ in recorder.record(buffer) }

            do {
                trace("调 capture.start()…")
                try capture.start()
                trace("capture.start() 返回 OK")
                report.append("采集已启动（tap 走硬件格式，转换成写入格式）")
                try? await Task.sleep(for: .seconds(2))
                capture.stop()
                trace("采集停止，共 \(recorder.frames) 帧")
            } catch {
                trace("capture.start() 抛错：\(error.localizedDescription)")
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL（起不来）")
                CaptureSelfTest.finish(report, code: 1)
                return
            }

            let seconds = Double(recorder.frames) / RecordingAudioFormat.sampleRate
            let reportedRate = recorder.sampleRate.map { String(Int($0)) } ?? "?"
            report.append(
                "2 秒共收到 \(recorder.buffers) 拍 / \(recorder.frames) 帧"
                    + "（≈ \(String(format: "%.2f", seconds)) 秒音频；"
                    + "每拍格式 \(reportedRate) Hz / \(recorder.channels) ch）"
            )
            report.append(
                "峰值 \(String(format: "%.4f", recorder.peak)) / "
                    + "平均 \(String(format: "%.5f", recorder.rms))"
            )
            check(
                recorder.frames > Int(RecordingAudioFormat.sampleRate),
                "采到的音频超过 1 秒（采集链路通了）",
                "采到的音频太少：\(recorder.frames) 帧"
            )
            check(
                recorder.channels == Int(RecordingAudioFormat.channels)
                    && recorder.sampleRate == RecordingAudioFormat.sampleRate,
                "每拍都已经是写入格式（44.1kHz / 双声道）",
                "格式不对：\(recorder.channels) ch / \(recorder.sampleRate ?? -1) Hz"
            )
            report.append(
                recorder.peak > 0.0001
                    ? "（有声音进来：峰值不为 0）"
                    : "（峰值 0：环境很静或麦克风静音——链路本身是通的）"
            )

            report.append("")
            report.append(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL（\(failures) 项）")
            CaptureSelfTest.finish(report, code: failures == 0 ? 0 : 1)
        }
    }
}

/// 采集统计（回调在音频线程上，自己加锁）。
///
/// @author ixxxxoooo
private nonisolated final class SampleRecorder: @unchecked Sendable {
    private struct Storage {
        var buffers = 0
        var frames = 0
        var peak: Float = 0
        var sum: Double = 0
        var samples = 0
        var sampleRate: Double?
        var channels = 0
    }

    private let lock = NSLock()
    private var storage = Storage()

    func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        storage.buffers += 1
        storage.frames += Int(buffer.frameLength)
        storage.sampleRate = buffer.format.sampleRate
        storage.channels = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for index in 0..<Int(buffer.frameLength) {
                let value = abs(data[channel][index])
                storage.peak = max(storage.peak, value)
                storage.sum += Double(value)
                storage.samples += 1
            }
        }
    }

    var buffers: Int { lock.withLock { storage.buffers } }
    var frames: Int { lock.withLock { storage.frames } }
    var peak: Float { lock.withLock { storage.peak } }
    var sampleRate: Double? { lock.withLock { storage.sampleRate } }
    var channels: Int { lock.withLock { storage.channels } }
    var rms: Double {
        lock.withLock { storage.samples > 0 ? storage.sum / Double(storage.samples) : 0 }
    }
}

#endif
