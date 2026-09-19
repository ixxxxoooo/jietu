import AppKit
import UserNotifications

/// 截图保存后的系统通知反馈。
///
/// 之前保存是全静默的，只能靠「最近截图」和浮窗间接确认；这里补一条通知，
/// 点击通知在访达里定位刚存下的文件。
///
/// 注意：`UNUserNotificationCenter.current()` 要求进程有正经 bundle（真机运行 OK，
/// 无 bundle 的命令行/自检场景会崩），所以入口统一做了 `bundleIdentifier` 判空。
///
/// @author ixxxxoooo
final class CaptureNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// 点击通知后要做的事：定位刚存下的文件，或打开某个系统设置面板。
    private var pendingAction: (() -> Void)?

    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// 申请通知权限；被拒绝时静默降级（仅通知不可用，不影响其它功能）。
    func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        // 不把 center 捕进回调里（它是非 Sendable 的），每次现取。
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
                if let error {
                    NSLog("[Jietu] notification authorization failed: \(error.localizedDescription)")
                    return
                }
                if !granted {
                    NSLog("[Jietu] notification permission denied")
                }
            }
        }
    }

    /// 保存成功后弹通知（带图片预览），点击定位文件。
    func notifySaved(fileURL: URL) {
        guard isAvailable else { return }

        pendingAction = { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        let content = UNMutableNotificationContent()
        content.title = "截图已保存"
        content.body = fileURL.lastPathComponent
        if let attachment = try? UNNotificationAttachment(
            identifier: "capture",
            url: fileURL,
            options: nil
        ) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[Jietu] post notification failed: \(error.localizedDescription)")
            }
        }
    }

    /// 录屏收工后的通知：视频做不了图片预览，就把时长写进副标题。
    func notifyRecordingCompleted(duration: TimeInterval) {
        guard isAvailable else { return }
        pendingAction = nil

        let total = max(0, Int(duration.rounded(.down)))
        let content = UNMutableNotificationContent()
        content.title = "录屏完成"
        content.body = String(format: "时长 %02d:%02d", total / 60, total % 60)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[Jietu] post recording notification failed: \(error.localizedDescription)")
            }
        }
    }

    /// 导出 / 裁剪完成的通知：GIF、裁剪片段这类从成片派生的文件。
    ///
    /// 标题由调用方给（「GIF 已导出」/「裁剪完成」），点击通知在访达中定位文件。
    func notifyExported(fileURL: URL, title: String) {
        guard isAvailable else { return }
        pendingAction = { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = fileURL.lastPathComponent
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[Jietu] post export notification failed: \(error.localizedDescription)")
            }
        }
    }

    /// 麦克风开关开着、这次却没能启用（未授权 / 没有输入设备）时的提示。
    ///
    /// 不做静默降级：用户开着麦克风就是想录旁白，录完才发现没声音是最糟的体验。
    /// 点击通知直接跳到系统设置的麦克风隐私面板。
    func notifyMicrophoneUnavailable() {
        guard isAvailable else { return }
        pendingAction = { NSWorkspace.shared.open(MicrophoneCapture.privacySettingsURL) }

        let content = UNMutableNotificationContent()
        content.title = "这次没能录到麦克风"
        content.body = "成片里只有系统声音。请在「系统设置 › 隐私与安全性 › 麦克风」里允许 Jietu，或检查输入设备。"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时也要出横幅（Jietu 是菜单栏代理 App，截完基本算前台）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        pendingAction?()
    }
}
