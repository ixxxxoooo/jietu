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
    /// 点击通知后要定位的文件。
    private var pendingURL: URL?

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

        pendingURL = fileURL
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
    func notifyRecordingSaved(fileURL: URL, duration: TimeInterval) {
        guard isAvailable else { return }
        pendingURL = fileURL

        let total = max(0, Int(duration.rounded(.down)))
        let content = UNMutableNotificationContent()
        content.title = "录屏已保存"
        content.body = String(
            format: "%@（%02d:%02d）", fileURL.lastPathComponent, total / 60, total % 60
        )
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
        guard let url = pendingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
