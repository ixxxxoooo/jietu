import AppKit
import Foundation

/// 系统设置里的一个隐私面板。
///
/// 抽出来是为了让「拖拽授权」面板同时服务多个权限：面板本身只要知道
/// 目标面板的深链、名字和拖拽提示就够了。
///
/// @author ixxxxoooo
enum PermissionPane {
    case screenRecording
    case accessibility

    /// 面板名字，用于 UI 文案。
    var title: String {
        switch self {
        case .screenRecording: return L10n.permPaneScreenRecording
        case .accessibility: return L10n.permPaneAccessibility
        }
    }

    /// `x-apple.systempreferences` 深链。
    var settingsURL: URL? {
        switch self {
        case .screenRecording:
            return URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        case .accessibility:
            return URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        }
    }

    /// 拖拽面板上的说明：告诉用户把卡片拖到哪一栏。
    var dragHint: String {
        switch self {
        case .screenRecording:
            return L10n.permPaneDragHintSR
        case .accessibility:
            return L10n.permPaneDragHintAX
        }
    }

    func openSystemSettings() {
        guard let settingsURL else { return }
        NSWorkspace.shared.open(settingsURL)
    }
}
