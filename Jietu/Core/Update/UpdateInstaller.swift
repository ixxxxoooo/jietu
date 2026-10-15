import CryptoKit
import Foundation

/// 下载进度转发器：只为拿 `didWriteData` 回调，文件落盘由 `URLSession.download` 的返回值处理。
private nonisolated final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// 更新安装器的「取包」阶段：下载 → 校验 SHA-256 → 解压 → 校验新 App。
/// 「替换并重启」阶段见 `UpdateInstaller+Install.swift`。
///
/// 校验链（任何一环失败都不会动现有 App）：
/// 1. zip 的 SHA-256 必须与发布方给出的摘要一致（`digest` 字段或 `.sha256` 文件）；
/// 2. 解压出的 App 的 bundle id 必须一致、版本必须与发布版本一致；
/// 3. `codesign --verify --deep --strict` 通过；
/// 4. 满足当前 App 的 designated requirement（同一张自签名证书）——
///    这条保证升级后「屏幕录制」授权仍然有效，也挡住被调包的安装包。
///
/// @author ixxxxoooo
nonisolated struct UpdateInstaller: Sendable {
    let network: UpdateNetwork
    let session: URLSession
    /// 下载 / 解压的临时目录。
    let workDirectory: URL

    init(
        network: UpdateNetwork = URLSessionUpdateNetwork(),
        session: URLSession = .shared,
        workDirectory: URL = UpdateInstaller.defaultWorkDirectory
    ) {
        self.network = network
        self.session = session
        self.workDirectory = workDirectory
    }

    static var defaultWorkDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("com.ixxxxoooo.jietu/Updates", isDirectory: true)
    }

    // MARK: - 下载 + 校验

    /// 下载安装包并校验 SHA-256。
    ///
    /// - Parameters:
    ///   - release: 目标版本。
    ///   - progress: 下载进度（0...1），在后台线程回调。
    /// - Returns: 校验通过的 zip 文件地址。
    @concurrent
    func download(
        _ release: ReleaseInfo,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let expected = try await expectedChecksum(for: release)
        let fm = FileManager.default
        let directory = workDirectory.appendingPathComponent(release.version.description, isDirectory: true)
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let zip = directory.appendingPathComponent(release.zipName)

        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(
                from: release.zipURL, delegate: DownloadProgressDelegate(progress))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? fm.removeItem(at: temporary)
            // 404 = 这个版本没挂安装包（比如只发了 DMG 的旧版本）。
            throw http.statusCode == 404 ? UpdateError.noInstallableAsset : UpdateError.httpStatus(http.statusCode)
        }
        do {
            try fm.moveItem(at: temporary, to: zip)
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
        progress(1)

        let actual = try Self.sha256(of: zip)
        guard actual == expected else {
            try? fm.removeItem(at: directory)
            throw UpdateError.checksumMismatch
        }
        return zip
    }

    /// 取得期望摘要：优先 API 内置的 `digest`，其次下载 `.sha256` 文件；两者都没有则拒绝安装。
    func expectedChecksum(for release: ReleaseInfo) async throws -> String {
        if let digest = release.sha256 { return digest }
        guard let url = release.checksumURL else { throw UpdateError.checksumMissing }
        let text: String
        do {
            let (data, _) = try await network.get(url, accept: "application/octet-stream")
            text = String(decoding: data, as: UTF8.self)
        } catch let error as UpdateError {
            throw error == .httpStatus(404) ? UpdateError.checksumMissing : error
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
        guard let hex = GitHubReleaseParser.parseChecksumFile(text) else { throw UpdateError.checksumMissing }
        return hex
    }

    /// 流式计算文件 SHA-256（1 MiB 一块，不把整个包读进内存）。
    static func sha256(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 解压 + 校验

    /// 解压 zip 并校验其中的 App。
    ///
    /// - Parameters:
    ///   - zip: 已校验 SHA-256 的安装包。
    ///   - release: 目标版本。
    ///   - bundleIdentifier: 期望的 bundle id（当前 App 的）。
    ///   - requirement: 当前 App 的 designated requirement；nil 表示跳过这一环
    ///     （ad-hoc 签名的开发包没有稳定身份可比）。
    /// - Returns: 解压出的 `.app` 地址。
    @concurrent
    func unpack(
        zip: URL,
        release: ReleaseInfo,
        bundleIdentifier: String,
        requirement: String?
    ) async throws -> URL {
        let fm = FileManager.default
        let output = zip.deletingLastPathComponent().appendingPathComponent("unpacked", isDirectory: true)
        try? fm.removeItem(at: output)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)

        let dittoResult = await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, output.path])
        guard dittoResult.status == 0 else { throw UpdateError.unpackFailed(dittoResult.output) }

        let contents = (try? fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.unpackFailed(L10n.s("update.error.no_app_in_zip"))
        }

        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleIdentifier else {
            throw UpdateError.validationFailed(L10n.s("update.error.bundle_id_mismatch"))
        }
        let shortVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard let packaged = SemanticVersion(shortVersion), packaged == release.version else {
            throw UpdateError.validationFailed(L10n.sf("update.error.version_mismatch", shortVersion))
        }

        let verify = await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else { throw UpdateError.validationFailed(verify.output) }

        if let requirement {
            let match = await Self.run(
                "/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + requirement, app.path])
            guard match.status == 0 else {
                throw UpdateError.validationFailed(L10n.s("update.error.identity_mismatch"))
            }
        }
        return app
    }

    /// 读取某个 App 的 designated requirement。
    ///
    /// - Returns: 稳定身份（如 `identifier … and certificate leaf = H"…"`）；
    ///   未签名或 ad-hoc 签名（退化成 `cdhash`）时返回 nil。
    @concurrent
    static func designatedRequirement(of app: URL) async -> String? {
        let result = await run("/usr/bin/codesign", ["-d", "-r-", app.path])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") where line.hasPrefix("designated => ") {
            let requirement = String(line.dropFirst("designated => ".count))
            return requirement.contains("cdhash") ? nil : requirement
        }
        return nil
    }
}
