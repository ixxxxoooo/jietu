import Foundation
import Testing

@testable import Jietu

struct UpdateCheckerTests {
    let api = URL(string: "https://api.github.com/repos/o/r/releases/latest")!
    let web = URL(string: "https://github.com/o/r/releases/latest")!

    @Test func API正常时直接解析() async throws {
        let data = UpdateFixtures.releaseJSON(version: "1.2.0")
        let checker = UpdateChecker(
            network: StubNetwork(routes: [api.absoluteString: .success((data, api))]),
            apiURL: api, fallbackRepository: "o/r")
        #expect(try await checker.fetchLatest().version.description == "1.2.0")
    }

    @Test func API被限流时回退到网页重定向() async throws {
        let final = URL(string: "https://github.com/o/r/releases/tag/v1.3.0")!
        let net = StubNetwork(routes: [
            api.absoluteString: .failure(UpdateError.httpStatus(403)),
            web.absoluteString: .success((Data("<html/>".utf8), final)),
        ])
        let latest = try await UpdateChecker(network: net, apiURL: api, fallbackRepository: "o/r").fetchLatest()
        #expect(latest.version.description == "1.3.0")
        #expect(
            latest.zipURL.absoluteString
                == "https://github.com/o/r/releases/download/v1.3.0/Lucent-1.3.0-macOS.zip")
        #expect(latest.checksumURL?.absoluteString.hasSuffix(".zip.sha256") == true)
        #expect(latest.sha256 == nil)
    }

    @Test func 最新版没有安装包时不回退() async {
        let data = UpdateFixtures.releaseJSON(version: "1.2.0", includeZip: false)
        let net = StubNetwork(routes: [api.absoluteString: .success((data, api))])
        let checker = UpdateChecker(network: net, apiURL: api, fallbackRepository: "o/r")
        await #expect(throws: UpdateError.noInstallableAsset) { try await checker.fetchLatest() }
    }

    @Test func 回退页面也无法识别时报错() async {
        let net = StubNetwork(routes: [
            api.absoluteString: .failure(UpdateError.httpStatus(500)),
            web.absoluteString: .success((Data(), web)),
        ])
        let checker = UpdateChecker(network: net, apiURL: api, fallbackRepository: "o/r")
        await #expect(throws: UpdateError.invalidResponse) { try await checker.fetchLatest() }
    }

    @Test func 覆盖地址时不回退() async {
        let net = StubNetwork(routes: [api.absoluteString: .failure(UpdateError.httpStatus(500))])
        let checker = UpdateChecker(network: net, apiURL: api, fallbackRepository: nil)
        await #expect(throws: UpdateError.httpStatus(500)) { try await checker.fetchLatest() }
    }

    @Test func 环境变量覆盖latest地址() {
        let c = UpdateChecker.makeDefault(
            environment: [UpdateChecker.apiOverrideEnvironmentKey: "http://127.0.0.1:1/latest.json"])
        #expect(c.apiURL.absoluteString == "http://127.0.0.1:1/latest.json")
        #expect(c.fallbackRepository == nil)
        let standard = UpdateChecker.makeDefault(environment: [:])
        #expect(standard.fallbackRepository == UpdateChecker.defaultRepository)
        #expect(standard.apiURL.absoluteString.contains("api.github.com/repos/ixxxxoooo/jietu/releases/latest"))
    }
}
