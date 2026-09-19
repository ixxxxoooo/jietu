import Foundation
import Observation

/// 截图落盘格式。
///
/// @author ixxxxoooo
enum SaveFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

/// Quick Access 预览卡出现的位置（屏幕左下 / 右下角）。
///
/// @author ixxxxoooo
enum QuickAccessPosition: String, CaseIterable, Identifiable {
    case bottomRight
    case bottomLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottomRight: return "右下角"
        case .bottomLeft: return "左下角"
        }
    }
}

/// 截选后流程设置。
///
/// @author ixxxxoooo
enum EditorMode: String, CaseIterable, Identifiable {
    /// 立即标注：截完直接在当前截图上编辑，工具栏原地出现，`✓/✗` 决定。
    case inline
    /// 浮窗预览：截完先显示浮窗卡片，点开后居中原地编辑。
    case quickAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inline: return "立即标注"
        case .quickAccess: return "浮窗预览"
        }
    }

    /// 从持久化值解析。兼容旧值 `window`：它曾表示「独立窗口编辑器」，
    /// 该语义已并入浮窗预览，不能让已选浮窗的设置被静默重置。
    init(storedValue: String?) {
        self = switch storedValue {
        case EditorMode.inline.rawValue: .inline
        case EditorMode.quickAccess.rawValue, "window": .quickAccess
        default: .inline
        }
    }
}
