import Foundation
import Testing

@testable import Jietu

/// 取包阶段：下载 + SHA-256 + 解压 + 签名 / 身份校验。
struct UpdateInstallerTests {
    private func installer(_ dir: URL, network: UpdateNetwork = StubNetwork(routes: [:])) -> UpdateInstaller {
        UpdateInstaller(network: network, workDirectory: dir.appendingPathComponent("work"))
    }

    /// 造一个 zip 好的 9.0.0 假 App。
    private func packaged(_ dir: URL, version: String = "9.0.0", bundleID: String = UpdateFixtures.bundleID)
        async throws -> (zip: URL, sha: String)
    {
        let app = try await UpdateFixtures.makeApp(at: dir, version: version, bundleID: bundleID)
        let (zip, sha) = try await UpdateFixtures.zip(app, version: version)
        return (zip, sha)
    }

    // MARK: 下载

    @Test func 下载校验通过并报告进度() async throws {
        let dir = UpdateFixtures.tempDir()
        let (zip, sha) = try await packaged(dir)
        let box = ProgressBox()
        let out = try await installer(dir).download(
            UpdateFixtures.release(version: "9.0.0", zip: zip, sha: sha)
        ) { box.record($0) }
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(box.last == 1)
    }

    @Test func 校验值不一致时拒绝并清掉文件() async throws {
        let dir = UpdateFixtures.tempDir()
        let (zip, _) = try await packaged(dir)
        let bad = String(repeating: "0", count: 64)
        let sut = installer(dir)
        await #expect(throws: UpdateError.checksumMismatch) {
            try await sut.download(UpdateFixtures.release(version: "9.0.0", zip: zip, sha: bad)) { _ in }
        }
        let leftover = sut.workDirectory.appendingPathComponent("9.0.0/\(zip.lastPathComponent)")
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func 没有任何校验信息时拒绝安装() async throws {
        let dir = UpdateFixtures.tempDir()
        let (zip, _) = try await packaged(dir)
        let sut = installer(dir)
        await #expect(throws: UpdateError.checksumMissing) {
            try await sut.download(UpdateFixtures.release(version: "9.0.0", zip: zip, sha: nil)) { _ in }
        }
    }

    @Test func 从sha256文件取得校验值() async throws {
        let dir = UpdateFixtures.tempDir()
        let (zip, sha) = try await packaged(dir)
        let checksum = URL(string: "https://example.com/Lucent-9.0.0-macOS.zip.sha256")!
        let text = "\(sha)  \(zip.lastPathComponent)\n"
        let net = StubNetwork(routes: [checksum.absoluteString: .success((Data(text.utf8), checksum))])
        let release = UpdateFixtures.release(version: "9.0.0", zip: zip, sha: nil, checksumURL: checksum)
        let out = try await installer(dir, network: net).download(release) { _ in }
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test func 校验文件404时按缺校验值处理() async throws {
        let dir = UpdateFixtures.tempDir()
        let (zip, _) = try await packaged(dir)
        let checksum = URL(string: "https://example.com/missing.sha256")!
        let release = UpdateFixtures.release(version: "9.0.0", zip: zip, sha: nil, checksumURL: checksum)
        let sut = installer(dir)
        await #expect(throws: UpdateError.checksumMissing) { try await sut.download(release) { _ in } }
    }

    @Test func 流式SHA256与一次性计算一致() async throws {
        let dir = UpdateFixtures.tempDir()
        // 3 MiB + 1：跨多个 1 MiB 块，还带一个不满块的尾巴。
        let data = Data((0..<(3 << 20) + 1).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let file = dir.appendingPathComponent("blob")
        try data.write(to: file)
        #expect(try UpdateInstaller.sha256(of: file) == UpdateFixtures.sha(of: data))
    }

    // MARK: 解压 + 校验

    @Test func 解压得到匹配的App() async throws {
        let dir = UpdateFixtures.tempDir()
        let (zip, sha) = try await packaged(dir)
        let sut = installer(dir)
        let release = UpdateFixtures.release(version: "9.0.0", zip: zip, sha: sha)
        let app = try await sut.unpack(
            zip: zip, release: release, bundleIdentifier: UpdateFixtures.bundleID, requirement: nil)
        #expect(app.lastPathComponent == UpdateFixtures.appName)
        #expect(Bundle(url: app)?.bundleIdentifier == UpdateFixtures.bundleID)
    }

    @Test func 包名不符的App被拒绝() async throws {
        let dir = UpdateFixtures.tempDir()
        let (zip, sha) = try await packaged(dir, bundleID: "com.evil.app")
        let release = UpdateFixtures.release(version: "9.0.0", zip: zip, sha: sha)
        let sut = installer(dir)
        await #expect(throws: UpdateError.self) {
            try await sut.unpack(
                zip: zip, release: release, bundleIdentifier: UpdateFixtures.bundleID, requirement: nil)
        }
    }

    @Test func 版本与发布不一致被拒绝() async throws {
        let dir = UpdateFixtures.tempDir()
        let (zip, sha) = try await packaged(dir, version: "9.0.0")
        let release = UpdateFixtures.release(version: "9.1.0", zip: zip, sha: sha)
        let sut = installer(dir)
        await #expect(throws: UpdateError.self) {
            try await sut.unpack(
                zip: zip, release: release, bundleIdentifier: UpdateFixtures.bundleID, requirement: nil)
        }
    }

    @Test func 打包后被篡改的App过不了签名校验() async throws {
        let dir = UpdateFixtures.tempDir()
        let app = try await UpdateFixtures.makeApp(at: dir, version: "9.0.0")
        // 签名之后再改资源，签名即失效。
        try "tampered".write(
            to: app.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
        let (zip, sha) = try await UpdateFixtures.zip(app, version: "9.0.0")
        let release = UpdateFixtures.release(version: "9.0.0", zip: zip, sha: sha)
        let sut = installer(dir)
        await #expect(throws: UpdateError.self) {
            try await sut.unpack(
                zip: zip, release: release, bundleIdentifier: UpdateFixtures.bundleID, requirement: nil)
        }
    }

    @Test func 签名身份必须满足当前App的设计要求() async throws {
        let dir = UpdateFixtures.tempDir()
        let (zip, sha) = try await packaged(dir)
        let release = UpdateFixtures.release(version: "9.0.0", zip: zip, sha: sha)
        let sut = installer(dir)

        // 满足：identifier 一致（ad-hoc 签名的 identifier 默认取 bundle id）。
        _ = try await sut.unpack(
            zip: zip, release: release, bundleIdentifier: UpdateFixtures.bundleID,
            requirement: "identifier \"\(UpdateFixtures.bundleID)\"")

        // 不满足：换成别的身份，必须被拒绝。
        await #expect(throws: UpdateError.self) {
            try await sut.unpack(
                zip: zip, release: release, bundleIdentifier: UpdateFixtures.bundleID,
                requirement: "identifier \"com.evil.app\"")
        }
    }

    @Test func 读取设计要求_ad_hoc退化成cdhash时视为没有() async throws {
        let dir = UpdateFixtures.tempDir()
        let app = try await UpdateFixtures.makeApp(at: dir, version: "1.0.0")
        #expect(await UpdateInstaller.designatedRequirement(of: app) == nil)
        #expect(await UpdateInstaller.designatedRequirement(of: dir.appendingPathComponent("nope.app")) == nil)
    }
}
