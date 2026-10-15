import Foundation
import Testing

@testable import Jietu

@MainActor
struct UpdateManagerTests {
    private func makePrefs() -> UpdatePreferences {
        UpdatePreferences(defaults: TestUserDefaults.make().0)
    }

    private func manager(
        latest: String, current: String, prefs: UpdatePreferences? = nil
    ) -> UpdateManager {
        UpdateManager(
            preferences: prefs ?? makePrefs(),
            checker: UpdateFixtures.checker(returning: UpdateFixtures.releaseJSON(version: latest)),
            currentVersion: SemanticVersion(current))
    }

    // MARK: 偏好

    @Test func 偏好默认自动检查且会持久化() {
        let (defaults, _) = TestUserDefaults.make()
        let prefs = UpdatePreferences(defaults: defaults)
        #expect(prefs.autoCheck)
        #expect(prefs.lastCheck == nil && prefs.skippedVersion == nil)

        prefs.autoCheck = false
        prefs.skippedVersion = "1.3.0"
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        prefs.lastCheck = stamp

        let reloaded = UpdatePreferences(defaults: defaults)
        #expect(!reloaded.autoCheck)
        #expect(reloaded.skippedVersion == "1.3.0")
        #expect(reloaded.lastCheck == stamp)
    }

    // MARK: 检查

    @Test func 发现新版本() async {
        let m = manager(latest: "1.3.0", current: "1.2.0")
        await m.check(userInitiated: true)
        #expect(m.availableRelease?.version.description == "1.3.0")
        #expect(m.hasAvailableUpdate)
        #expect(m.menuTitle.contains("1.3.0"))
        #expect(m.preferences.lastCheck != nil)
    }

    @Test func 已是最新或本地更高() async {
        let same = manager(latest: "1.2.0", current: "1.2.0")
        await same.check(userInitiated: true)
        #expect(same.state == .upToDate)
        #expect(same.menuTitle == L10n.updateMenuCheck)

        let ahead = manager(latest: "1.2.0", current: "1.3.0")
        await ahead.check(userInitiated: true)
        #expect(ahead.state == .upToDate)
    }

    @Test func 跳过版本后自动检查静默而手动检查仍提示() async {
        let prefs = makePrefs()
        let m = manager(latest: "1.3.0", current: "1.2.0", prefs: prefs)
        await m.check(userInitiated: true)
        m.skipAvailableVersion()
        #expect(prefs.skippedVersion == "1.3.0")
        #expect(m.state == .upToDate)

        await m.check(userInitiated: false)
        #expect(m.state == .upToDate)

        await m.check(userInitiated: true)
        #expect(m.availableRelease != nil)
        #expect(!m.hasAvailableUpdate, "被跳过的版本不应再亮提示")
    }

    @Test func 手动检查失败有提示_自动检查失败静默() async {
        let bad = UpdateChecker(
            network: StubNetwork(routes: [UpdateFixtures.latestURL.absoluteString: .failure(UpdateError.httpStatus(500))]),
            apiURL: UpdateFixtures.latestURL, fallbackRepository: nil)
        let m = UpdateManager(preferences: makePrefs(), checker: bad, currentVersion: SemanticVersion("1.2.0"))
        await m.check(userInitiated: false)
        #expect(m.state == .idle)
        await m.check(userInitiated: true)
        guard case .failed(let message) = m.state else {
            Issue.record("手动检查失败应展示错误: \(m.state)")
            return
        }
        #expect(message.contains("500"))
        m.dismissFailure()
        #expect(m.state == .idle)
    }

    @Test func 自动检查遵守开关与6小时间隔() async {
        let prefs = makePrefs()
        let m = manager(latest: "1.3.0", current: "1.2.0", prefs: prefs)

        prefs.autoCheck = false
        await m.autoCheckIfDue()
        #expect(m.state == .idle, "关掉自动检查后不应发请求")

        prefs.autoCheck = true
        prefs.lastCheck = Date().addingTimeInterval(-3600)
        await m.autoCheckIfDue()
        #expect(m.state == .idle, "距上次不足 6 小时不应发请求")

        prefs.lastCheck = Date().addingTimeInterval(-UpdateManager.autoCheckInterval - 60)
        await m.autoCheckIfDue()
        #expect(m.availableRelease != nil)
    }

    // MARK: 安装

    /// 造一个指向本地 zip 的 latest 检测器，并返回（旧 App、检测器、工作目录）。
    private func installFixture(newVersion: String = "2.0.0", digestOverride: String? = nil) async throws
        -> (old: URL, checker: UpdateChecker, work: URL, dir: URL)
    {
        let dir = UpdateFixtures.tempDir()
        let installDir = dir.appendingPathComponent("Applications")
        let newDir = dir.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let old = try await UpdateFixtures.makeApp(at: installDir, version: "1.0.0", marker: "old")
        let new = try await UpdateFixtures.makeApp(at: newDir, version: newVersion, marker: "new")
        let (zip, sha) = try await UpdateFixtures.zip(new, version: newVersion)
        let json = UpdateFixtures.releaseJSON(version: newVersion, zipURL: zip, digest: digestOverride ?? sha)
        return (old, UpdateFixtures.checker(returning: json), dir.appendingPathComponent("work"), dir)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func 完整更新流程替换应用并请求退出() async throws {
        let f = try await installFixture()
        let m = UpdateManager(
            preferences: makePrefs(), checker: f.checker,
            installer: UpdateInstaller(workDirectory: f.work),
            currentVersion: SemanticVersion("1.0.0"), bundleIdentifier: UpdateFixtures.bundleID,
            bundleURL: f.old, processID: try UpdateFixtures.deadPID(),
            installLogURL: f.dir.appendingPathComponent("update.log"), relaunchAfterInstall: false)
        var terminated = false
        m.terminate = { terminated = true }

        await m.check(userInitiated: true)
        m.installAvailableUpdate()
        try await waitUntil { terminated }
        #expect(terminated, "安装脚本启动后应请求退出，当前状态 \(m.state)")

        // 脚本异步运行，轮询等替换完成。
        let marker = f.old.appendingPathComponent("Contents/marker.txt")
        try await waitUntil { (try? String(contentsOf: marker, encoding: .utf8)) == "new" }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "new")
    }

    @Test func 校验值错误时不安装并报错() async throws {
        let f = try await installFixture(digestOverride: String(repeating: "0", count: 64))
        let m = UpdateManager(
            preferences: makePrefs(), checker: f.checker,
            installer: UpdateInstaller(workDirectory: f.work),
            currentVersion: SemanticVersion("1.0.0"), bundleIdentifier: UpdateFixtures.bundleID,
            bundleURL: f.old, installLogURL: f.dir.appendingPathComponent("update.log"),
            relaunchAfterInstall: false)
        var terminated = false
        m.terminate = { terminated = true }

        await m.check(userInitiated: true)
        m.installAvailableUpdate()
        try await waitUntil {
            if case .failed = m.state { return true }
            return false
        }
        guard case .failed = m.state else {
            Issue.record("应进入失败态: \(m.state)")
            return
        }
        #expect(!terminated)
        let marker = f.old.appendingPathComponent("Contents/marker.txt")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "old", "校验失败不能动现有 App")
    }

    @Test func 无法原地安装时给出手动替换入口() async throws {
        let f = try await installFixture()
        // 路径含 AppTranslocation：系统把它放在只读随机位置，没法原地替换。
        let translocated = f.dir.appendingPathComponent("AppTranslocation/ABC/d")
        try FileManager.default.createDirectory(at: translocated, withIntermediateDirectories: true)
        let running = try await UpdateFixtures.makeApp(at: translocated, version: "1.0.0")
        let m = UpdateManager(
            preferences: makePrefs(), checker: f.checker,
            installer: UpdateInstaller(workDirectory: f.work),
            currentVersion: SemanticVersion("1.0.0"), bundleIdentifier: UpdateFixtures.bundleID,
            bundleURL: running)
        var terminated = false
        m.terminate = { terminated = true }
        await m.check(userInitiated: true)
        m.installAvailableUpdate()
        try await waitUntil {
            if case .failed = m.state { return true }
            return false
        }
        guard case .failed = m.state else {
            Issue.record("应进入失败态: \(m.state)")
            return
        }
        #expect(m.manualInstallURL?.lastPathComponent == UpdateFixtures.appName)
        #expect(!terminated)
    }

    @Test func 签名身份不匹配的包在安装前被拦下() async throws {
        let f = try await installFixture()
        // 当前 App 换成系统自带 App：它的设计要求是 Apple 锚点，ad-hoc 的新包必然不满足。
        let m = UpdateManager(
            preferences: makePrefs(), checker: f.checker,
            installer: UpdateInstaller(workDirectory: f.work),
            currentVersion: SemanticVersion("1.0.0"), bundleIdentifier: UpdateFixtures.bundleID,
            bundleURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        await m.check(userInitiated: true)
        m.installAvailableUpdate()
        try await waitUntil {
            if case .failed = m.state { return true }
            return false
        }
        guard case .failed = m.state else {
            Issue.record("应进入失败态: \(m.state)")
            return
        }
        #expect(m.manualInstallURL == nil, "身份校验没过的包不能被引导去手动安装")
    }
}
