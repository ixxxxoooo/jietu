import Foundation

/// 界面语言：跟随系统，或锁定中文 / 英文。
///
/// 写入 `AppleLanguages` 后重启进程即可让系统框架与 `L10n` 一起切换。
///
/// @author ygw
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.languageSystem
        case .chinese: return L10n.languageChinese
        case .english: return L10n.languageEnglish
        }
    }

    /// 对应 `.lproj` 目录名；`nil` 表示走系统首选语言。
    nonisolated var localizationCode: String? {
        switch self {
        case .system: return nil
        case .chinese: return "zh-Hans"
        case .english: return "en"
        }
    }

    /// 解析当前实际要用的语言码（供 `L10n` / 图标选择等立刻生效）。
    nonisolated var resolvedCode: String {
        if let localizationCode { return localizationCode }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        return "en"
    }

    /// 写入 UserDefaults，使本进程与下次启动都生效。
    func apply() {
        if let code = localizationCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}
