import CoreGraphics
import Foundation

enum CaptureError: LocalizedError {
    case permissionDenied
    case noShareableContent(String)
    case noDisplays
    case displayNotShareable(CGDirectDisplayID)
    case emptyImage(CGDirectDisplayID)
    case emptyRegion
    case windowNotCapturable(CGWindowID)
    case noWindowUnderCursor

    /// 直接用 `CFBundleCopyLocalizedString` 而不走 `L10n`——
    /// `LocalizedError.errorDescription` 是 `nonisolated` 协议要求，
    /// 而 `L10n` 的静态属性会被 Swift 6 推断为 `@MainActor`（Bundle 相关依赖链）。
    private static func _l(_ key: String) -> String {
        let result = CFBundleCopyLocalizedString(
            CFBundleGetMainBundle(), key as CFString, key as CFString, "Localizable" as CFString
        )
        return result as String? ?? key
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return Self._l("error.permission_denied")
        case .noShareableContent(let detail):
            return String(format: Self._l("error.no_shareable_content"), detail)
        case .noDisplays:
            return Self._l("error.no_displays")
        case .displayNotShareable(let id):
            return String(format: Self._l("error.display_not_shareable"), id)
        case .emptyImage(let id):
            return String(format: Self._l("error.empty_image"), id)
        case .emptyRegion:
            return Self._l("error.empty_region")
        case .windowNotCapturable(let id):
            return String(format: Self._l("error.window_not_capturable"), id)
        case .noWindowUnderCursor:
            return Self._l("error.no_window_under_cursor")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return Self._l("error.recovery_permission")
        case .noShareableContent, .displayNotShareable, .emptyImage, .windowNotCapturable:
            return Self._l("error.recovery_relaunch")
        case .noDisplays:
            return Self._l("error.recovery_no_displays")
        case .emptyRegion:
            return Self._l("error.recovery_empty_region")
        case .noWindowUnderCursor:
            return Self._l("error.recovery_no_window")
        }
    }

    /// 这类失败重启一下基本就好（屏幕录制的授权在授权时的那个进程里不生效）。
    var suggestsRelaunch: Bool {
        switch self {
        case .permissionDenied, .noShareableContent, .displayNotShareable, .emptyImage,
            .windowNotCapturable:
            return true
        case .noDisplays, .emptyRegion, .noWindowUnderCursor:
            return false
        }
    }
}
