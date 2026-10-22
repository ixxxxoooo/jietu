import Foundation

/// GitHub Release JSON 解析器（纯函数）。
///
/// @author ixxxxoooo
nonisolated enum GitHubReleaseParser {
    private struct Asset: Decodable {
        let name: String
        let size: Int64?
        let browserDownloadUrl: URL
        let digest: String?
    }

    private struct Payload: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlUrl: URL
        let draft: Bool?
        let prerelease: Bool?
        let publishedAt: Date?
        let assets: [Asset]
    }

    /// 安装包命名约定：`Jietu-<版本>-macOS.zip`（由 `Scripts/build-dmg.sh` 产出）。
    static func isInstallableAsset(_ name: String) -> Bool { name.hasSuffix("-macOS.zip") }

    /// 解析 `releases/latest` 响应。
    ///
    /// - Parameter data: JSON 数据。
    /// - Returns: 发布信息；草稿、版本号无法识别、没有安装包时抛出错误。
    static func parse(_ data: Data) throws -> ReleaseInfo {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw UpdateError.invalidResponse
        }
        guard payload.draft != true, let version = SemanticVersion(payload.tagName) else {
            throw UpdateError.invalidResponse
        }
        guard let zip = payload.assets.first(where: { isInstallableAsset($0.name) }) else {
            throw UpdateError.noInstallableAsset
        }
        let checksumAsset = payload.assets.first { $0.name == zip.name + ".sha256" }
        return ReleaseInfo(
            version: version,
            tag: payload.tagName,
            name: payload.name.flatMap { $0.isEmpty ? nil : $0 } ?? payload.tagName,
            notes: releaseNotes(from: payload.body),
            pageURL: payload.htmlUrl,
            publishedAt: payload.publishedAt,
            zipURL: zip.browserDownloadUrl,
            zipName: zip.name,
            zipSize: zip.size ?? 0,
            sha256: parseDigest(zip.digest),
            checksumURL: checksumAsset?.browserDownloadUrl
        )
    }

    /// 更新说明只要「改了什么」：发布正文里 `### Installation` 起的安装 / 权限说明
    /// 是给首次下载 DMG 的人看的，对已经装好的用户是噪音，裁掉。
    static func releaseNotes(from body: String?) -> String {
        let text = body ?? ""
        let head = text.components(separatedBy: "\n### Installation").first ?? text
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把 Release 的 Markdown 整理成界面能直接渲染的「行内 Markdown」：
    /// `#` 标题 → 加粗行，`- ` / `* ` 列表 → `• `，其余原样保留（行内粗体 / 链接由系统渲染）。
    static func displayMarkdown(_ notes: String) -> String {
        notes.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            if line.hasPrefix("#") {
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? "" : "**\(title)**"
            }
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return "• " + trimmed.dropFirst(2)
            }
            return line
        }.joined(separator: "\n")
    }

    /// 解析 API 的 `digest` 字段（形如 `sha256:abcd…`）。
    static func parseDigest(_ digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        return normalizeHex(String(digest.dropFirst(7)))
    }

    /// 解析 `shasum` 输出（`<hex>  <文件名>`），取第一个 64 位十六进制串。
    static func parseChecksumFile(_ text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            if let hex = normalizeHex(String(token)) { return hex }
        }
        return nil
    }

    private static func normalizeHex(_ text: String) -> String? {
        let lower = text.lowercased()
        guard lower.count == 64, lower.allSatisfy({ $0.isHexDigit }) else { return nil }
        return lower
    }
}
