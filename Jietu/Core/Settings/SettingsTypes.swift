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
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inline: return "立即标注"
        case .window: return "浮窗预览"
        }
    }
}
