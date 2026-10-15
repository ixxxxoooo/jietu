import Foundation

/// 在线更新相关文案。
///
/// 访问器全部 `nonisolated`：`UpdateError` 等非主线程类型也要用。
///
/// @author ixxxxoooo
extension L10n {
    nonisolated static var updateMenuCheck: String { s("update.menu.check") }
    nonisolated static func updateMenuAvailable(_ value: String) -> String { sf("update.menu.available", value) }
    nonisolated static var updateSection: String { s("update.section") }
    nonisolated static var updateCurrentVersion: String { s("update.current_version") }
    nonisolated static var updateAutoCheck: String { s("update.auto_check") }
    nonisolated static var updateCheckNow: String { s("update.check_now") }
    nonisolated static var updateChecking: String { s("update.checking") }
    nonisolated static var updateUpToDate: String { s("update.up_to_date") }
    nonisolated static func updateLastChecked(_ value: String) -> String { sf("update.last_checked", value) }
    nonisolated static func updateAvailableTitle(_ value: String) -> String { sf("update.available_title", value) }
    nonisolated static var updateInstall: String { s("update.install") }
    nonisolated static var updateSkip: String { s("update.skip") }
    nonisolated static var updateReleaseNotes: String { s("update.release_notes") }
    nonisolated static var updateViewRelease: String { s("update.view_release") }
    nonisolated static func updateDownloading(_ value: Int) -> String { sf("update.downloading", value) }
    nonisolated static var updateCancel: String { s("update.cancel") }
    nonisolated static var updateVerifying: String { s("update.verifying") }
    nonisolated static var updateInstalling: String { s("update.installing") }
    nonisolated static var updateRetry: String { s("update.retry") }
    nonisolated static var updateDismiss: String { s("update.dismiss") }
    nonisolated static var updateShowInFinder: String { s("update.show_in_finder") }
    nonisolated static var updateManualDownload: String { s("update.manual_download") }
    nonisolated static var updateFooter: String { s("update.footer") }
    nonisolated static var updateDevNote: String { s("update.dev_note") }
}
