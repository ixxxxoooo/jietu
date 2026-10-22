import Foundation

/// 更新检测使用的网络抽象，便于单元测试注入。
nonisolated protocol UpdateNetwork: Sendable {
    /// GET 请求。
    ///
    /// - Parameters:
    ///   - url: 地址。
    ///   - accept: `Accept` 头。
    /// - Returns: 响应体与最终 URL（跟随重定向之后）。
    func get(_ url: URL, accept: String) async throws -> (Data, URL)
}

/// 基于 `URLSession` 的实现：10 秒超时，不用缓存。
nonisolated struct URLSessionUpdateNetwork: UpdateNetwork {
    private let session: URLSession

    init(timeout: TimeInterval = 10) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func get(_ url: URL, accept: String) async throws -> (Data, URL) {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Jietu-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return (data, response.url ?? url)
    }
}

/// 最新版本检测器：优先走 REST API，被限流 / 失败时回退到 `releases/latest` 网页重定向
/// （不占 API 配额），两条路径都能得到可安装的 `ReleaseInfo`。
///
/// @author ixxxxoooo
nonisolated struct UpdateChecker: Sendable {
    /// 项目仓库（owner/name）。
    static let defaultRepository = "ixxxxoooo/jietu"
    /// 测试 / 镜像时可用这个环境变量替换 latest 接口地址（此时不启用网页回退）。
    static let apiOverrideEnvironmentKey = "JIETU_UPDATE_API"

    let network: UpdateNetwork
    let apiURL: URL
    /// 网页回退使用的仓库；为 nil 表示禁用回退。
    let fallbackRepository: String?

    /// 默认检测器：读取环境变量覆盖，否则指向官方仓库。
    static func makeDefault(
        network: UpdateNetwork = URLSessionUpdateNetwork(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UpdateChecker {
        if let override = environment[apiOverrideEnvironmentKey], let url = URL(string: override) {
            return UpdateChecker(network: network, apiURL: url, fallbackRepository: nil)
        }
        let api = URL(string: "https://api.github.com/repos/\(defaultRepository)/releases/latest")!
        return UpdateChecker(network: network, apiURL: api, fallbackRepository: defaultRepository)
    }

    /// 获取最新正式版。
    func fetchLatest() async throws -> ReleaseInfo {
        do {
            let (data, _) = try await network.get(apiURL, accept: "application/vnd.github+json")
            return try GitHubReleaseParser.parse(data)
        } catch let error as UpdateError where error == .noInstallableAsset {
            // 最新版确实没有安装包，回退也无意义。
            throw error
        } catch {
            guard let repository = fallbackRepository else { throw error }
            return try await fetchViaWebRedirect(repository: repository)
        }
    }

    /// 回退路径：请求 `releases/latest` 网页，从最终地址 `/releases/tag/<tag>` 取得标签，
    /// 再按命名约定拼出下载地址。
    private func fetchViaWebRedirect(repository: String) async throws -> ReleaseInfo {
        let page = URL(string: "https://github.com/\(repository)/releases/latest")!
        let (_, finalURL) = try await network.get(page, accept: "text/html")
        let parts = finalURL.pathComponents
        guard let index = parts.lastIndex(of: "tag"), index + 1 < parts.count,
            let version = SemanticVersion(parts[index + 1])
        else {
            throw UpdateError.invalidResponse
        }
        let tag = parts[index + 1]
        let zipName = "Jietu-\(version)-macOS.zip"
        let base = "https://github.com/\(repository)/releases/download/\(tag)/"
        return ReleaseInfo(
            version: version, tag: tag, name: tag, notes: "",
            pageURL: finalURL, publishedAt: nil,
            zipURL: URL(string: base + zipName)!, zipName: zipName, zipSize: 0,
            sha256: nil, checksumURL: URL(string: base + zipName + ".sha256")
        )
    }
}
