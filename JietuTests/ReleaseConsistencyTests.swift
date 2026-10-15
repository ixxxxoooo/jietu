import Foundation
import Testing
@testable import Jietu

/// 发版一致性：工程版本号、CHANGELOG 与 App 自己的版本必须是同一个。
///
/// 读的是仓库里的真实文件（按本文件位置回溯到仓库根），
/// 与 `Scripts/check-release.sh`（CI 的 verify 任务）是同一套规则。
///
/// @author ixxxxoooo
@Suite("发版一致性")
struct ReleaseConsistencyTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func marketingVersions() throws -> Set<String> {
        let project = try read("Jietu.xcodeproj/project.pbxproj")
        let regex = try Regex(#"MARKETING_VERSION = ([^;]+);"#)
        return Set(project.matches(of: regex).compactMap { $0.output[1].substring.map(String.init) })
    }

    @Test("工程里所有 configuration 的 MARKETING_VERSION 相同，且是 x.y.z 形式")
    func projectVersionsAgree() throws {
        let versions = try marketingVersions()
        #expect(versions.count == 1, "MARKETING_VERSION 不一致：\(versions.sorted())")
        let version = try #require(versions.first)
        #expect(version.wholeMatch(of: #/\d+\.\d+\.\d+/#) != nil, "版本号应为 x.y.z：\(version)")
    }

    @Test("CHANGELOG 第一条版本条目等于工程版本")
    func changelogMatchesProjectVersion() throws {
        let version = try #require(try marketingVersions().first)
        let changelog = try read("CHANGELOG.md")
        let heading = try #require(changelog.firstMatch(of: #/(?m)^## \[(\d+\.\d+\.\d+)\]/#))
        #expect(String(heading.output.1) == version, "CHANGELOG 最新是 \(heading.output.1)，工程是 \(version)")
    }

    @Test("运行中的 App 报告的版本号就是工程版本")
    func bundleVersionMatchesProject() throws {
        let version = try #require(try marketingVersions().first)
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #expect(bundleVersion == version)
    }
}
