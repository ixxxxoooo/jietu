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
        case .bottomRight: return L10n.quickAccessBottomRight
        case .bottomLeft: return L10n.quickAccessBottomLeft
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
        case .inline: return L10n.annotationEditorModeInline
        case .quickAccess: return L10n.annotationEditorModeQuickAccess
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

/// GIF 导出分辨率与尺寸偏好。
///
/// @author ixxxxoooo
nonisolated enum GifResolution: String, CaseIterable, Identifiable, Sendable {
    /// 50% 视网膜推荐：Retina 2x 物理像素还原至 1x 逻辑像素，文字锐利且体积小。
    case retina1x
    /// 100% 原始尺寸：像素 1:1，最高清晰度。
    case original
    /// 75% 高清缩放。
    case scale75
    /// 33% 轻量缩放。
    case scale33
    /// 限制最大宽度 960 像素（不放大）。
    case width960
    /// 限制最大宽度 640 像素（不放大）。
    case width640
    /// 限制最大宽度 480 像素（不放大）。
    case width480

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .retina1x: return L10n.gifResolutionRetina1x
        case .original: return L10n.gifResolutionOriginal
        case .scale75: return L10n.gifResolutionScale75
        case .scale33: return L10n.gifResolutionScale33
        case .width960: return L10n.gifResolutionWidth960
        case .width640: return L10n.gifResolutionWidth640
        case .width480: return L10n.gifResolutionWidth480
        }
    }

    /// 根据源视频尺寸计算导出的宽高（等比缩放、取偶数、不放大）。
    func calculateSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let width = max(2, sourceWidth)
        let height = max(2, sourceHeight)
        let scale: Double
        switch self {
        case .original: scale = 1.0
        case .scale75: scale = 0.75
        case .retina1x: scale = 0.50
        case .scale33: scale = 0.33
        case .width960: scale = min(1.0, 960.0 / Double(width))
        case .width640: scale = min(1.0, 640.0 / Double(width))
        case .width480: scale = min(1.0, 480.0 / Double(width))
        }
        return VideoEncodingSettings.evenDimensions(
            width: max(2, Int((Double(width) * scale).rounded())),
            height: max(2, Int((Double(height) * scale).rounded()))
        )
    }
}

/// GIF 导出画质偏好。
///
/// @author ixxxxoooo
nonisolated enum GifQuality: String, CaseIterable, Identifiable, Sendable {
    /// 高画质：完整色彩调色板，原色保真，高品质抗锯齿采样。
    case high
    /// 平衡：推荐档位，高保真抗锯齿采样配合轻度阶调优化，兼顾清晰度与体积。
    case medium
    /// 压缩优先：压缩色彩阶数，大幅减小动图体积，便于分享。
    case low

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .high: return L10n.gifQualityHigh
        case .medium: return L10n.gifQualityMedium
        case .low: return L10n.gifQualityLow
        }
    }
}

