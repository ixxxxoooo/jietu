import Foundation
import Testing
@testable import Jietu

/// FilenameTemplate 的边界条件测试——侧重 Unicode、超长、特殊字符等极端情况。
///
/// @author ygw
@Suite("文件名模板边界")
struct FilenameTemplateBoundaryTests {

    /// 按**本地时区**的 2026-09-16 10:59:31 构造（别写死时间戳：格式化器走当前时区，
    /// 写死的话在 UTC 的 CI 上会渲染成 02:59:31）。
    private let date: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 16
        components.hour = 10
        components.minute = 59
        components.second = 31
        return Calendar.current.date(from: components)!
    }()

    // MARK: - Unicode

    @Test("CJK 模板正常展开")
    func cjkTemplateWorks() {
        let name = FilenameTemplate.makeName(template: "截图_{date}", date: date)
        #expect(name.hasPrefix("截图_"))
        #expect(name.contains("2026-09-16"))
    }

    @Test("Emoji 模板正常展开")
    func emojiTemplateWorks() {
        let name = FilenameTemplate.makeName(template: "🎯{date}📸", date: date)
        #expect(name.hasPrefix("🎯"))
        #expect(name.hasSuffix("📸"))
    }

    @Test("混合 CJK + Emoji + ASCII 模板")
    func mixedUnicodeTemplateWorks() {
        let name = FilenameTemplate.makeName(template: "截图-shot-🖼️-{counter}", date: date, counter: 5)
        #expect(name == "截图-shot-🖼️-5")
    }

    // MARK: - 超长模板

    @Test("200 字符的超长模板能正常展开")
    func longTemplateWorks() {
        let prefix = String(repeating: "a", count: 200)
        let name = FilenameTemplate.makeName(template: "\(prefix)_{date}", date: date)
        #expect(name.count > 200, "超长模板不应被截断")
        #expect(name.hasPrefix(prefix))
    }

    // MARK: - 特殊字符清洗

    @Test("多个连续斜杠被逐个替换")
    func multipleSlashesReplaced() {
        let resolved = FilenameTemplate.resolvedTemplate("a///b")
        #expect(!resolved.contains("/"))
        #expect(resolved == "a---b")
    }

    @Test("冒号和斜杠混合的模板被清洗")
    func mixedIllegalCharacters() {
        let resolved = FilenameTemplate.resolvedTemplate("folder/sub:dir/{date}")
        #expect(!resolved.contains("/"))
        #expect(!resolved.contains(":"))
    }

    // MARK: - datetime 占位符

    @Test("{datetime} 展开为日期 + 时间的组合")
    func datetimePlaceholder() {
        let name = FilenameTemplate.makeName(template: "Shot {datetime}", date: date)
        #expect(name.contains("2026-09-16"))
        #expect(name.contains("10.59.31"))
        #expect(name.contains(" at "), "datetime 中间应有 at 分隔")
    }

    // MARK: - usesCounter 检测

    @Test("usesCounter 能识别被非法字符替换后仍存在的 {counter}")
    func usesCounterAfterSanitize() {
        // 模板里有斜杠但 counter 没被破坏
        #expect(FilenameTemplate.usesCounter("a/b-{counter}") == true)
    }

    @Test("usesCounter 对大小写敏感")
    func usesCounterCaseSensitive() {
        #expect(FilenameTemplate.usesCounter("{COUNTER}") == false, "{COUNTER} 不应被识别")
        #expect(FilenameTemplate.usesCounter("{Counter}") == false)
    }

    // MARK: - captureDate 解析

    @Test("标准 Jietu 文件名能解析出日期")
    func standardJietuNameParsesDate() {
        let url = URL(fileURLWithPath: "/tmp/Jietu 2026-09-16 at 10.59.31.png")
        let parsed = FilenameTemplate.captureDate(of: url)
        let calendar = Calendar.current
        #expect(calendar.component(.year, from: parsed) == 2026)
        #expect(calendar.component(.month, from: parsed) == 9)
        #expect(calendar.component(.day, from: parsed) == 16)
    }

    @Test("非 Jietu 前缀的文件名不走解析逻辑")
    func nonJietuNameDoesNotParse() {
        let url = URL(fileURLWithPath: "/tmp/Screenshot 2026-09-16 at 10.59.31.png")
        let parsed = FilenameTemplate.captureDate(of: url)
        // 不崩溃，返回某个合理值（文件不存在时用 Date()）
        #expect(parsed.timeIntervalSince1970 > 0)
    }

    @Test("Jietu 文件名但时间格式异常时回落到文件时间")
    func malformedJietuNameFallsBack() {
        let url = URL(fileURLWithPath: "/tmp/Jietu XXXX-YY-ZZ at AA.BB.CC.png")
        let parsed = FilenameTemplate.captureDate(of: url)
        #expect(parsed.timeIntervalSince1970 > 0, "格式异常时不应崩溃")
    }

    // MARK: - nextCounter 边界

    @Test("模板不含 {counter} 时序号固定为 1")
    func nextCounterWithoutPlaceholder() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = FilenameTemplate.nextCounter(template: "Jietu {date}", in: dir, fileExtension: "png")
        #expect(counter == 1, "没有 {counter} 时固定返回 1")
    }

    @Test("空目录的 counter 从 1 开始")
    func nextCounterInEmptyDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = FilenameTemplate.nextCounter(template: "Jietu {counter}", in: dir, fileExtension: "png")
        #expect(counter == 1)
    }
}
