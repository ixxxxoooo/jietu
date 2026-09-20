import SwiftUI

/// 设置页的分类（侧栏一项 = 一个分区 = 右侧一个 `Form`）。
///
/// @author ixxxxoooo
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case capture
    case hotkeys
    case quickAccess
    case recording
    case annotation
    case permission
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.settingsGeneral
        case .appearance: return L10n.settingsAppearance
        case .capture: return L10n.settingsCapture
        case .hotkeys: return L10n.settingsHotkeys
        case .quickAccess: return L10n.settingsQuickAccess
        case .recording: return L10n.settingsRecording
        case .annotation: return L10n.settingsAnnotation
        case .permission: return L10n.settingsPermission
        case .about: return L10n.settingsAbout
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .capture: return "camera.viewfinder"
        case .hotkeys: return "keyboard"
        case .quickAccess: return "rectangle.on.rectangle"
        case .recording: return "record.circle"
        case .annotation: return "pencil.tip.crop.circle"
        case .permission: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}
