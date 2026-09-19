import AVFoundation
import Foundation

/// 麦克风权限工具。
///
/// 录屏的麦克风采集已改用 ScreenCaptureKit 原生的 `captureMicrophone`（系统级混音，
/// 质量比手动拆帧混合高得多）。这里只保留权限查询和申请的静态方法，供录屏前检查用。
///
/// @author ixxxxoooo
nonisolated enum MicrophonePermission {
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
}

/// 兼容别名：老代码引用 `MicrophoneCapture.requestPermission()` / `.privacySettingsURL`。
typealias MicrophoneCapture = MicrophonePermission
