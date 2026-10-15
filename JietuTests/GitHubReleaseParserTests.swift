import Foundation
import Testing

@testable import Jietu

struct GitHubReleaseParserTests {
    @Test func 解析真实结构的发布信息() throws {
        let hex = String(repeating: "ab", count: 32)
        let release = try GitHubReleaseParser.parse(UpdateFixtures.releaseJSON(version: "1.2.0", digest: hex))
        #expect(release.version.description == "1.2.0")
        #expect(release.tag == "v1.2.0")
        #expect(release.name == "Lucent 1.2.0")
        #expect(release.zipName == "Lucent-1.2.0-macOS.zip")
        #expect(release.zipSize == 4_096_000)
        // 摘要统一为小写（fixture 里给的是大写）。
        #expect(release.sha256 == hex)
        #expect(release.checksumURL?.lastPathComponent == "Lucent-1.2.0-macOS.zip.sha256")
        #expect(release.notes.contains("Online update"))
        #expect(release.publishedAt != nil)
    }

    @Test func 忽略DMG只认zip() throws {
        let release = try GitHubReleaseParser.parse(UpdateFixtures.releaseJSON(version: "1.2.0"))
        #expect(release.zipURL.pathExtension == "zip")
    }

    @Test func 没有digest时仍可解析并保留校验文件地址() throws {
        let release = try GitHubReleaseParser.parse(UpdateFixtures.releaseJSON(version: "1.2.0", digest: nil))
        #expect(release.sha256 == nil)
        #expect(release.checksumURL != nil)
    }

    @Test func 草稿被拒绝() {
        let data = UpdateFixtures.releaseJSON(version: "1.2.0", draft: true)
        #expect(throws: UpdateError.invalidResponse) { try GitHubReleaseParser.parse(data) }
    }

    @Test func 只有DMG时报没有可安装包() {
        let data = UpdateFixtures.releaseJSON(version: "1.2.0", includeZip: false)
        #expect(throws: UpdateError.noInstallableAsset) { try GitHubReleaseParser.parse(data) }
    }

    @Test func 坏数据被拒绝() {
        #expect(throws: UpdateError.invalidResponse) { try GitHubReleaseParser.parse(Data("{}".utf8)) }
        #expect(throws: UpdateError.invalidResponse) { try GitHubReleaseParser.parse(Data("nope".utf8)) }
    }

    @Test func 无法识别的标签被拒绝() {
        let json = String(decoding: UpdateFixtures.releaseJSON(version: "1.2.0"), as: UTF8.self)
            .replacingOccurrences(of: "\"v1.2.0\"", with: "\"nightly\"")
        #expect(throws: UpdateError.invalidResponse) { try GitHubReleaseParser.parse(Data(json.utf8)) }
    }

    @Test func 校验文件与digest格式() {
        let hex = String(repeating: "ab", count: 32)
        #expect(GitHubReleaseParser.parseChecksumFile("\(hex)  Lucent-1.2.0-macOS.zip\n") == hex)
        #expect(GitHubReleaseParser.parseChecksumFile("SHA256 (x.zip) = \(hex.uppercased())") == hex)
        #expect(GitHubReleaseParser.parseChecksumFile("not a checksum") == nil)
        #expect(GitHubReleaseParser.parseDigest("sha256:\(hex)") == hex)
        #expect(GitHubReleaseParser.parseDigest("sha1:abc") == nil)
        #expect(GitHubReleaseParser.parseDigest("sha256:short") == nil)
        #expect(GitHubReleaseParser.parseDigest(nil) == nil)
    }

    @Test func 更新说明裁掉安装与权限说明() {
        let body = "## Lucent 1.2.0\n\n- Online update\n\n### Installation\n\n1. Download the DMG"
        let notes = GitHubReleaseParser.releaseNotes(from: body)
        #expect(notes.contains("Online update"))
        #expect(!notes.contains("Installation") && !notes.contains("Download the DMG"))
        #expect(GitHubReleaseParser.releaseNotes(from: nil) == "")
    }

    @Test func 更新说明转成可渲染的行内Markdown() {
        let md = "## Lucent 1.2.0\n\n### Added\n- **Online** update\n  * nested\nplain"
        let shown = GitHubReleaseParser.displayMarkdown(md)
        #expect(shown == "**Lucent 1.2.0**\n\n**Added**\n• **Online** update\n• nested\nplain")
        #expect(GitHubReleaseParser.displayMarkdown("#") == "")
    }
}
