import SwiftUI

/// 设置页的分类（侧栏一项 = 一个分区 = 右侧一个 `Form`）。
///
/// @author ixxxxoooo
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case capture
    case hotkeys
    case quickAccess
    case annotation
    case permission
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .capture: return "截图"
        case .hotkeys: return "快捷键"
        case .quickAccess: return "预览浮窗"
        case .annotation: return "标注"
        case .permission: return "权限"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "camera.viewfinder"
        case .hotkeys: return "keyboard"
        case .quickAccess: return "rectangle.on.rectangle"
        case .annotation: return "pencil.tip.crop.circle"
        case .permission: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}
