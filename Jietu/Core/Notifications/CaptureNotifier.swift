import AppKit
import UserNotifications
import os

/// 通知这条路上的日志。
///
/// 以前这里全用 `NSLog`，而 `NSLog` 在这个 App 里并不进统一日志——于是「设置里勾了
/// 『保存后显示系统通知』、保存完却什么都没有」变成一件查不到原因的事故：
/// 到底是没权限、没申请、还是投递失败，日志里一个字都没有。统一改走 os.Logger，
/// 并把授权状态本身也打出来。
private let notifyLog = Logger(subsystem: "com.ixxxxoooo.jietu", category: "notifications")

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

    /// 授权状态的可读名字（仅限日志；`rawValue` 是数字，看不出含义）。
    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    /// 设置页开关打开时也能申请权限（不必等下次启动）。
    static func requestAuthorizationShared() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        // 菜单栏 App 默认不激活，系统有时会把授权弹窗压住——先抢前台。
        NSApp.activate(ignoringOtherApps: true)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            notifyLog.notice(
                "status on request: \(Self.describe(settings.authorizationStatus), privacy: .public)"
            )
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        notifyLog.error(
                            "authorization failed: \(error.localizedDescription, privacy: .public)"
                        )
                        return
                    }
                    notifyLog.notice("authorization granted: \(granted, privacy: .public)")
                }
            case .denied:
                notifyLog.notice(
                    "authorization denied — turn it on in System Settings › Notifications"
                )
            default:
                break
            }
        }
    }

    /// 挂上 delegate。**必须尽早**（`applicationWillFinishLaunching` 里就挂）：
    /// App 自己在前台时，系统默认不出横幅，要由 delegate 的 `willPresent` 明确要一个；
    /// 挂晚了系统就不会来问，于是「通知进了通知中心、右上角却不弹横幅」。
    func installDelegate() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let alreadyInstalled = center.delegate === self
        center.delegate = self
        if !alreadyInstalled {
            notifyLog.notice("delegate installed")
        }
    }

    /// 申请通知权限；被拒绝时静默降级（仅通知不可用，不影响其它功能）。
    func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        installDelegate()
        Self.requestAuthorizationShared()
    }

    /// 读一次当前授权状态。设置页靠它显示「系统那边被关掉了」。
    static func currentAuthorization() async -> UNAuthorizationStatus {
        guard Bundle.main.bundleIdentifier != nil else { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 打开「系统设置 › 通知 › Jietu」这一页。
    ///
    /// `?id=<bundle id>` 是通知面板支持的深链，直接落到本 App 的设置页，
    /// 省得用户在一长串 App 里翻。
    static func openSystemNotificationSettings() {
        guard let id = Bundle.main.bundleIdentifier,
            let url = URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)"
            )
        else { return }
        NSWorkspace.shared.open(url)
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
            notifyLog.notice(
                "post \(title, privacy: .public) — status \(Self.describe(settings.authorizationStatus), privacy: .public)"
            )
            switch settings.authorizationStatus {
            case .notDetermined:
                // 还没问过：先申请，授权成功后再发这一条。
                center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
                    if let error {
                        notifyLog.error(
                            "authorization failed: \(error.localizedDescription, privacy: .public)"
                        )
                        return
                    }
                    guard granted else {
                        notifyLog.notice("authorization refused by the user")
                        return
                    }
                    self?.enqueue(title: title, body: body, attachmentURL: attachmentURL)
                }
            case .authorized, .provisional, .ephemeral:
                self.enqueue(title: title, body: body, attachmentURL: attachmentURL)
            case .denied:
                notifyLog.notice(
                    "skipped — notifications are off for this app in System Settings › Notifications"
                )
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
                notifyLog.error("post failed: \(error.localizedDescription, privacy: .public)")
            } else {
                notifyLog.notice("posted \(request.identifier, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时也要出横幅（Jietu 是菜单栏代理 App，截完基本算前台）。
    ///
    /// 这条回调是横幅的**唯一开关**：App 在前台时系统默认只把它塞进通知中心，
    /// 不调这里、或者这里没要 `.banner`，右上角就不会弹。所以留一行日志，
    /// 下次「只进通知中心、没有横幅」时一眼能看出系统到底有没有来问。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        notifyLog.notice(
            "willPresent while frontmost: \(notification.request.identifier, privacy: .public) — asking for banner"
        )
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
