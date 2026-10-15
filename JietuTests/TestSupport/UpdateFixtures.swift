import CryptoKit
import Foundation
import Testing

@testable import Jietu

/// 可编排响应的网络桩：按 URL 返回预设结果，没配的一律 404。
nonisolated struct StubNetwork: UpdateNetwork {
    var routes: [String: Result<(Data, URL), Error>]

    func get(_ url: URL, accept: String) async throws -> (Data, URL) {
        guard let result = routes[url.absoluteString] else { throw UpdateError.httpStatus(404) }
        return try result.get()
    }
}

/// 线程安全的进度记录器（下载回调来自网络线程）。
nonisolated final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func record(_ v: Double) {
        lock.lock()
        value = v
        lock.unlock()
    }
    var last: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// 更新相关测试的共享脚手架：假 App、zip、发布 JSON。
enum UpdateFixtures {
    static let bundleID = "com.ixxxxoooo.jietu"
    static let appName = "Lucent.app"
    static let latestURL = URL(string: "https://api.test/latest")!

    static func tempDir(_ name: String = UUID().uuidString) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucent-update-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 构造一个 ad-hoc 签名的最小 App 包。
    @discardableResult
    static func makeApp(
        at dir: URL, version: String, bundleID: String = bundleID, marker: String = ""
    ) async throws -> URL {
        let app = dir.appendingPathComponent(appName)
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("Lucent").path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version,
            "CFBundleVersion": "1", "CFBundleExecutable": "Lucent", "CFBundlePackageType": "APPL",
        ]
        (plist as NSDictionary).write(
            to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try marker.write(
            to: app.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
        let sign = await UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
        #expect(sign.status == 0, "\(sign.output)")
        return app
    }

    /// 把 App 打成 zip，返回 (zip, sha256)。
    static func zip(_ app: URL, version: String) async throws -> (URL, String) {
        let zip = app.deletingLastPathComponent().appendingPathComponent("Lucent-\(version)-macOS.zip")
        let r = await UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        #expect(r.status == 0, "\(r.output)")
        return (zip, sha(of: try Data(contentsOf: zip)))
    }

    static func sha(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 指向本地 zip 的发布信息（下载走 file://）。
    static func release(
        version: String, zip: URL, sha: String?, checksumURL: URL? = nil
    ) -> ReleaseInfo {
        ReleaseInfo(
            version: SemanticVersion(version)!, tag: "v\(version)", name: "v\(version)", notes: "notes",
            pageURL: URL(string: "https://example.com/r")!, publishedAt: nil,
            zipURL: zip, zipName: zip.lastPathComponent, zipSize: 0, sha256: sha, checksumURL: checksumURL)
    }

    /// 一个已结束的进程号（安装脚本不必等待）。
    static func deadPID() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    /// 仿 GitHub `releases/latest` 的 JSON。
    ///
    /// - Parameters:
    ///   - version: 版本号（标签为 `v<version>`）。
    ///   - zipURL: 安装包地址；默认是 GitHub 下载地址。
    ///   - digest: `sha256:` 之后的摘要；nil 表示 API 不带 digest。
    ///   - includeZip: false 时只放一个 DMG（模拟旧版没有 zip）。
    ///   - includeChecksumAsset: 是否带 `.sha256` 资产。
    static func releaseJSON(
        version: String, zipURL: URL? = nil, digest: String? = String(repeating: "ab", count: 32),
        includeZip: Bool = true, includeChecksumAsset: Bool = true, draft: Bool = false
    ) -> Data {
        let name = "Lucent-\(version)-macOS.zip"
        let base = "https://github.com/ixxxxoooo/jietu/releases/download/v\(version)/"
        var assets: [[String: Any]] = [
            ["name": "Lucent-\(version).dmg", "size": 8_000_000, "browser_download_url": base + "Lucent-\(version).dmg"]
        ]
        if includeZip {
            var zip: [String: Any] = [
                "name": name, "size": 4_096_000,
                "browser_download_url": (zipURL?.absoluteString ?? base + name),
            ]
            if let digest { zip["digest"] = "sha256:\(digest.uppercased())" }
            assets.append(zip)
            if includeChecksumAsset {
                assets.append(["name": name + ".sha256", "size": 100, "browser_download_url": base + name + ".sha256"])
            }
        }
        let json: [String: Any] = [
            "tag_name": "v\(version)", "name": "Lucent \(version)", "body": "## Changes\n- Online update",
            "draft": draft, "prerelease": false,
            "html_url": "https://github.com/ixxxxoooo/jietu/releases/tag/v\(version)",
            "published_at": "2026-10-16T08:00:00Z", "assets": assets,
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    /// 用桩网络把 `latestURL` 指向给定 JSON 的检测器。
    static func checker(returning data: Data) -> UpdateChecker {
        UpdateChecker(
            network: StubNetwork(routes: [latestURL.absoluteString: .success((data, latestURL))]),
            apiURL: latestURL, fallbackRepository: nil)
    }
}
