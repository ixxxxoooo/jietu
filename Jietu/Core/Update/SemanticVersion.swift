import Foundation

/// 语义化版本：主.次.修订[-预发布][+构建元数据]。
///
/// 支持 `v` 前缀、缺省补零、预发布标识；构建元数据不参与比较。
///
/// @author ixxxxoooo
nonisolated struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// 预发布标识（如 `beta.1`）；为空表示正式版。
    let prerelease: [String]

    /// 解析版本字符串。
    ///
    /// - Parameter string: 形如 `v1.2.3`、`1.2`、`1.2.3-beta.1+45` 的字符串。
    /// - Returns: 解析失败返回 nil。
    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            pre = text[text.index(after: dash)...].split(separator: ".").map(String.init)
            text = String(text[..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
        prerelease = pre
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // 正式版高于同号预发布版。
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            // 数字标识按数值比较，且低于字母标识。
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
