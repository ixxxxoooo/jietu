import Foundation
import Testing
@testable import Jietu

/// 文件名模板展开与序号推断。
///
/// @author ixxxxoooo
@Suite("文件名模板")
struct FilenameTemplateTests {
    /// 按**本地时区**的 2026-09-16 10:59:31 构造。
    /// 别写死时间戳：格式化器用的是当前时区，写死的话在 UTC 的 CI 上会变成 02:59:31。
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

    @Test("默认模板与历史命名格式一致")
    func defaultTemplateMatchesLegacyName() {
        let name = FilenameTemplate.makeName(template: FilenameTemplate.defaultTemplate, date: date)
        #expect(name == "Jietu 2026-09-16 at 10.59.31")
    }

    @Test("展开各个占位符")
    func expandsPlaceholders() {
        let name = FilenameTemplate.makeName(
            template: "Shot-{date}-{time}-{counter}",
            date: date,
            counter: 7
        )
        #expect(name == "Shot-2026-09-16-10.59.31-7")
    }

    @Test("空模板回落到默认模板")
    func emptyTemplateFallsBack() {
        #expect(
            FilenameTemplate.makeName(template: "   ", date: date)
                == FilenameTemplate.makeName(template: FilenameTemplate.defaultTemplate, date: date)
        )
    }

    @Test("非法字符被替换，模板不会写到子目录")
    func sanitizesIllegalCharacters() {
        let cleaned = FilenameTemplate.resolvedTemplate("a/b:c-{time}")
        #expect(!cleaned.contains("/"))
        #expect(!cleaned.contains(":"))
    }

    @Test("按目录里已有文件推断下一个序号")
    func nextCounterScansDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let template = "Jietu {counter}"
        #expect(FilenameTemplate.nextCounter(template: template, in: directory, fileExtension: "png") == 1)

        for name in ["Jietu 1.png", "Jietu 2.png", "Jietu 3.png", "其它.png"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        #expect(FilenameTemplate.nextCounter(template: template, in: directory, fileExtension: "png") == 4)
    }

    @Test("序号从 1 起步")
    func counterStartsAtOne() {
        let name = FilenameTemplate.makeName(template: "Jietu-{counter}", date: date, counter: 0)
        #expect(name == "Jietu-1")
    }
}
