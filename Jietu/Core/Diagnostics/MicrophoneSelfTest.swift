import AVFoundation
import Foundation

#if DEBUG

/// 麦克风权限自检：确认授权状态和系统设置跳转。
///
/// 录屏的麦克风采集已改用 ScreenCaptureKit 原生的 `captureMicrophone`，
/// 不再需要手动验 AVAudioEngine 链路。这里只验权限。
///
///   Jietu --selftest-microphone
///
/// @author ixxxxoooo
enum MicrophoneSelfTest {

    static func run() {
        Task { @MainActor in
            var report: [String] = []

            let authorized = await MicrophonePermission.requestPermission()
            let permissionText = authorized ? "已授权" : "**没给**（系统设置里允许后重跑）"
            report.append("麦克风权限：\(permissionText)")
            report.append("设置页 URL：\(MicrophonePermission.privacySettingsURL)")

            if authorized {
                report.append("RESULT: PASS")
            } else {
                report.append("RESULT: FAIL（没权限）")
            }
            CaptureSelfTest.finish(report, code: authorized ? 0 : 1)
        }
    }
}

#endif
