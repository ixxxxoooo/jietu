import Foundation

/// 截图文件名模板：把 `{date}` / `{time}` / `{datetime}` / `{counter}` 展开成实际文件名。
///
/// 默认模板 `Jietu {date} at {time}` 与历史版本的文件名完全一致，
/// 所以老用户的「最近截图」时间解析不会受影响。
///
/// @author ixxxxoooo
enum FilenameTemplate {
    static let defaultTemplate = "Jietu {date} at {time}"

    static let placeholders = ["{date}", "{time}", "{datetime}", "{counter}"]
    static var placeholderHint: String { L10n.filenamePlaceholderHint }

    /// 文件名里不允许出现的字符（路径分隔与 HFS 兼容冒号）。
    private static let illegalCharacters = CharacterSet(charactersIn: "/:")

    /// 展开模板。`counter` 为 0 时 `{counter}` 退化为 1。
    static func makeName(template: String, date: Date, counter: Int = 0) -> String {
        let resolved = resolvedTemplate(template)
        let name = resolved
            .replacingOccurrences(of: "{date}", with: datePart(date))
            .replacingOccurrences(of: "{time}", with: timePart(date))
            .replacingOccurrences(of: "{datetime}", with: "\(datePart(date)) at \(timePart(date))")
            .replacingOccurrences(of: "{counter}", with: String(max(1, counter)))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? makeName(template: defaultTemplate, date: date) : trimmed
    }

    /// 模板是否用到了递增序号。
    static func usesCounter(_ template: String) -> Bool {
        resolvedTemplate(template).contains("{counter}")
    }

    /// 扫描目录里已有的同模板文件，推出下一个可用的序号。
    ///
    /// 只比较「除序号外完全相同」的文件名，因此模板里带 `{date}` 时序号是按天累计的。
    static func nextCounter(template: String, in directory: URL, fileExtension: String) -> Int {
        guard usesCounter(template) else { return 1 }

        let date = Date()
        let parts = resolvedTemplate(template).components(separatedBy: "{counter}")
        guard parts.count == 2 else { return 1 }
        let prefix = expand(parts[0], date: date)
        let suffix = expand(parts[1], date: date)

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var maxCounter = 0
        for entry in entries {
            guard entry.hasSuffix(".\(fileExtension)") else { continue }
            let stem = String(entry.dropLast(fileExtension.count + 1))
            guard stem.hasPrefix(prefix), stem.hasSuffix(suffix) else { continue }
            let middle = stem.dropFirst(prefix.count).dropLast(suffix.count)
            if let value = Int(middle) {
                maxCounter = max(maxCounter, value)
            }
        }
        return maxCounter + 1
    }

    /// 清洗模板：去掉路径分隔符，空模板回落到默认模板。
    static func resolvedTemplate(_ template: String) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultTemplate }
        return trimmed
            .components(separatedBy: illegalCharacters)
            .joined(separator: "-")
    }

    /// 从文件名（`Jietu yyyy-MM-dd at HH.mm.ss`）解析截图时刻，失败则用文件创建时间。
    static func captureDate(of url: URL) -> Date {
        let name = url.lastPathComponent
        if name.hasPrefix("Jietu "), let separator = name.range(of: " at ") {
            let datePart = String(name[name.index(name.startIndex, offsetBy: 6)..<separator.lowerBound])
            let timePart = String(name[separator.upperBound...].prefix(8))
            if let date = dateTimeFormatter.date(from: "\(datePart) \(timePart)") {
                return date
            }
        }
        return (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }

    private static let dateTimeFormatter: DateFormatter = formatter("yyyy-MM-dd HH.mm.ss")

    private static func expand(_ fragment: String, date: Date) -> String {
        fragment
            .replacingOccurrences(of: "{date}", with: datePart(date))
            .replacingOccurrences(of: "{time}", with: timePart(date))
            .replacingOccurrences(of: "{datetime}", with: "\(datePart(date)) at \(timePart(date))")
    }

    private static func datePart(_ date: Date) -> String {
        formatter("yyyy-MM-dd").string(from: date)
    }

    private static func timePart(_ date: Date) -> String {
        formatter("HH.mm.ss").string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
