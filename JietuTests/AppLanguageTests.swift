import Foundation
import Testing
@testable import Jietu

/// 界面语言选项：语言码解析与展示。
///
/// 不测 `apply()`：它写的是 `UserDefaults.standard` 的 `AppleLanguages`，
/// 会连带改动同进程里并行的其它测试所看到的语言。
///
/// @author ixxxxoooo
@Suite("界面语言")
struct AppLanguageTests {
    @Test("锁定语言给出固定的 .lproj 目录名，跟随系统为 nil")
    func localizationCodes() {
        #expect(AppLanguage.system.localizationCode == nil)
        #expect(AppLanguage.chinese.localizationCode == "zh-Hans")
        #expect(AppLanguage.english.localizationCode == "en")
    }

    @Test("resolvedCode：锁定语言原样返回，跟随系统只会落到 zh-Hans 或 en")
    func resolvedCodes() {
        #expect(AppLanguage.chinese.resolvedCode == "zh-Hans")
        #expect(AppLanguage.english.resolvedCode == "en")
        #expect(["zh-Hans", "en"].contains(AppLanguage.system.resolvedCode))
    }

    @Test("rawValue 往返，id 等于 rawValue；三个选项都有可显示的标题")
    func identityAndTitles() {
        #expect(AppLanguage.allCases.count == 3)
        for language in AppLanguage.allCases {
            #expect(AppLanguage(rawValue: language.rawValue) == language)
            #expect(language.id == language.rawValue)
            #expect(!language.title.isEmpty)
        }
    }

    @Test("每个 .lproj 目录名都对应真实存在的本地化资源")
    func localizationCodesHaveResources() {
        for language in AppLanguage.allCases {
            guard let code = language.localizationCode else { continue }
            #expect(
                Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: code) != nil,
                "\(code) 缺 Localizable.strings"
            )
        }
    }
}
