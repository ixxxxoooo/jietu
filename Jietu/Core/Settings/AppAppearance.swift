import AppKit

/// 整个 App 的外观：跟随系统，或锁定浅色 / 深色。
///
/// 参考项目 `AppAppearance` 的做法：`system` 交还给 AppKit（`nil`），
/// 这样改 macOS 外观时不用重启也能跟着变。
///
/// @author ixxxxoooo
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.appearanceSystem
        case .light: return L10n.appearanceLight
        case .dark: return L10n.appearanceDark
        }
    }

    /// `nil` 交还给 AppKit，由它跟随 macOS。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// 应用到整个进程（所有窗口一起变）。
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }
}
