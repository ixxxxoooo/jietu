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
/// @author ygw
final class CaptureNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// 点击通知后要做的事：定位刚存下的文件，或打开某个系统设置面板。
    private var pendingAction: (() -> Void)?

    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// 设置页开关打开时也能申请权限（不必等下次启动）。
    static func requestAuthorizationShared() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        // 菜单栏 App 默认不激活，系统有时会把授权弹窗压住——先抢前台。
        NSApp.activate(ignoringOtherApps: true)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        NSLog("[Jietu] notification authorization failed: \(error.localizedDescription)")
                        return
                    }
                    if !granted {
                        NSLog("[Jietu] notification permission denied")
                    }
                }
            case .denied:
                NSLog("[Jietu] notification permission denied — enable in System Settings › Notifications")
            default:
                break
            }
        }
    }

    /// 申请通知权限；被拒绝时静默降级（仅通知不可用，不影响其它功能）。
    func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        Self.requestAuthorizationShared()
    }

    /// 保存成功后弹通知（带图片预览），点击定位文件。
    func notifySaved(fileURL: URL) {
        post(
            title: L10n.notifySaved,
            body: fileURL.lastPathComponent,
            attachmentURL: fileURL,
            action: { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        )
    }

    /// 录屏收工后的通知：视频做不了图片预览，就把时长写进副标题。
    func notifyRecordingCompleted(duration: TimeInterval) {
        let total = max(0, Int(duration.rounded(.down)))
        post(
            title: L10n.notifyRecordingComplete,
            body: L10n.notifyDuration(total / 60, total % 60),
            attachmentURL: nil,
            action: nil
        )
    }

    /// 导出 / 裁剪完成的通知：GIF、裁剪片段这类从成片派生的文件。
    ///
    /// 标题由调用方给（「GIF 已导出」/「裁剪完成」），点击通知在访达中定位文件。
    func notifyExported(fileURL: URL, title: String) {
        post(
            title: title,
            body: fileURL.lastPathComponent,
            attachmentURL: nil,
            action: { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        )
    }

    /// 麦克风开关开着、这次却没能启用（未授权 / 没有输入设备）时的提示。
    ///
    /// 不做静默降级：用户开着麦克风就是想录旁白，录完才发现没声音是最糟的体验。
    /// 点击通知直接跳到系统设置的麦克风隐私面板。
    func notifyMicrophoneUnavailable() {
        post(
            title: L10n.notifyMicUnavailable,
            body: L10n.notifyMicUnavailableBody,
            attachmentURL: nil,
            action: { NSWorkspace.shared.open(MicrophoneCapture.privacySettingsURL) }
        )
    }

    /// 统一发通知：先确认授权，再挂附件（附件失败不阻断整条通知）。
    private func post(
        title: String,
        body: String,
        attachmentURL: URL?,
        action: (() -> Void)?
    ) {
        guard isAvailable else { return }
        pendingAction = action

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .notDetermined:
                // 还没问过：先申请，授权成功后再发这一条。
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        NSLog("[Jietu] notification authorization failed: \(error.localizedDescription)")
                        return
                    }
                    guard granted else {
                        NSLog("[Jietu] notification permission denied")
                        return
                    }
                    self.enqueue(title: title, body: body, attachmentURL: attachmentURL)
                }
            case .authorized, .provisional, .ephemeral:
                self.enqueue(title: title, body: body, attachmentURL: attachmentURL)
            case .denied:
                NSLog("[Jietu] skip notification — permission denied")
            @unknown default:
                self.enqueue(title: title, body: body, attachmentURL: attachmentURL)
            }
        }
    }

    private func enqueue(title: String, body: String, attachmentURL: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let attachmentURL,
            let attachment = try? UNNotificationAttachment(
                identifier: "capture",
                url: attachmentURL,
                options: nil
            )
        {
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

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时也要出横幅（Jietu 是菜单栏代理 App，截完基本算前台）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
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
