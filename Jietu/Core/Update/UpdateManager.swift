import Foundation
import Observation
import os

/// 更新流程状态。
nonisolated enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(ReleaseInfo)
    case downloading(ReleaseInfo, progress: Double)
    case verifying(ReleaseInfo)
    case installing(ReleaseInfo)
    case failed(String)

    /// 写进日志的简短描述（不含下载进度，避免刷屏）。
    var logDescription: String {
        switch self {
        case .idle: return "idle"
        case .checking: return "checking"
        case .upToDate: return "up-to-date"
        case .available(let r): return "available \(r.version)"
        case .downloading(let r, _): return "downloading \(r.version)"
        case .verifying(let r): return "verifying \(r.version)"
        case .installing(let r): return "installing \(r.version)"
        case .failed(let message): return "failed: \(message)"
        }
    }
}

/// 更新相关的用户偏好：存 `UserDefaults`，可观察（设置页的开关直接绑它）。
@MainActor
@Observable
final class UpdatePreferences {
    private enum Key {
        static let auto = "autoCheckUpdates"
        static let last = "lastUpdateCheck"
        static let skipped = "skippedUpdateVersion"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// 是否自动检查更新（默认开）。
    var autoCheck: Bool {
        didSet { defaults.set(autoCheck, forKey: Key.auto) }
    }
    /// 上次成功检查的时间。
    var lastCheck: Date? {
        didSet { defaults.set(lastCheck, forKey: Key.last) }
    }
    /// 用户选择跳过的版本号。
    var skippedVersion: String? {
        didSet { defaults.set(skippedVersion, forKey: Key.skipped) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoCheck = defaults.object(forKey: Key.auto) as? Bool ?? true
        lastCheck = defaults.object(forKey: Key.last) as? Date
        skippedVersion = defaults.string(forKey: Key.skipped)
    }
}

/// 在线更新的状态机与对外入口：自动 / 手动检查 → 发现新版 → 下载校验 → 原地替换并重启。
/// 界面只读 `state`，所有动作都通过本类触发。
///
/// @author ixxxxoooo
@MainActor
@Observable
final class UpdateManager {
    /// 自动检查的最小间隔。
    static let autoCheckInterval: TimeInterval = 6 * 3600

    private(set) var state: UpdateState = .idle {
        didSet {
            if !Self.isProgressOnly(oldValue, state) { Log.update.notice("state → \(self.state.logDescription, privacy: .public)") }
        }
    }
    /// 无法原地安装时，已下载好的新版 App 位置（引导用户在 Finder 里手动替换）。
    private(set) var manualInstallURL: URL?

    let preferences: UpdatePreferences
    @ObservationIgnored private let checker: UpdateChecker
    @ObservationIgnored private let installer: UpdateInstaller
    @ObservationIgnored private let currentVersion: SemanticVersion
    @ObservationIgnored private let bundleIdentifier: String
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let processID: Int32
    @ObservationIgnored private let installLogURL: URL
    @ObservationIgnored private let relaunchAfterInstall: Bool
    /// 安装脚本启动后调用，应退出 App。
    @ObservationIgnored var terminate: @MainActor () -> Void = {}
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var autoCheckTask: Task<Void, Never>?

    /// 当前版本号（来自 Info.plist）。
    var current: SemanticVersion { currentVersion }

    /// 是否正在检查或安装。
    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    /// 当前可更新的版本（含下载 / 校验 / 安装中）。
    var availableRelease: ReleaseInfo? {
        switch state {
        case .available(let r), .downloading(let r, _), .verifying(let r), .installing(let r): return r
        default: return nil
        }
    }

    /// 是否有应当提示的新版本（用户跳过的版本不提示，安装进行中除外）。
    var hasAvailableUpdate: Bool {
        guard let release = availableRelease else { return false }
        return isBusy || release.version.description != preferences.skippedVersion
    }

    /// 菜单栏条目标题：有新版本时直接点明版本号。
    var menuTitle: String {
        if hasAvailableUpdate, let release = availableRelease {
            return L10n.updateMenuAvailable(release.version.description)
        }
        return L10n.updateMenuCheck
    }

    init(
        preferences: UpdatePreferences = UpdatePreferences(),
        checker: UpdateChecker = .makeDefault(),
        installer: UpdateInstaller = UpdateInstaller(),
        currentVersion: SemanticVersion? = nil,
        bundleIdentifier: String? = nil,
        bundleURL: URL = Bundle.main.bundleURL,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        installLogURL: URL = UpdateInstaller.installLogURL,
        relaunchAfterInstall: Bool = true
    ) {
        self.preferences = preferences
        self.checker = checker
        self.installer = installer
        let plistVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.currentVersion = currentVersion ?? plistVersion.flatMap(SemanticVersion.init) ?? SemanticVersion("0.0.0")!
        self.bundleIdentifier = bundleIdentifier ?? Bundle.main.bundleIdentifier ?? "com.ixxxxoooo.jietu"
        self.bundleURL = bundleURL
        self.processID = processID
        self.installLogURL = installLogURL
        self.relaunchAfterInstall = relaunchAfterInstall
    }

    // MARK: - 自动检查

    /// 启动自动检查：启动后稍等片刻检查一次，之后每小时判断一次是否到期。
    func startAutoCheck(initialDelay: Duration = .seconds(8)) {
        autoCheckTask?.cancel()
        autoCheckTask = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                if let self { await self.autoCheckIfDue() }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func stopAutoCheck() {
        autoCheckTask?.cancel()
        autoCheckTask = nil
    }

    func autoCheckIfDue() async {
        guard preferences.autoCheck, !isBusy else { return }
        if let last = preferences.lastCheck, Date().timeIntervalSince(last) < Self.autoCheckInterval { return }
        await check(userInitiated: false)
    }

    // MARK: - 检查

    /// 检查更新。
    ///
    /// - Parameter userInitiated: 手动检查会展示「已是最新 / 失败」结果；自动检查失败时保持静默。
    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        let previous = state
        state = .checking
        do {
            let latest = try await checker.fetchLatest()
            preferences.lastCheck = Date()
            if latest.version > currentVersion {
                // 自动检查尊重「跳过此版本」；手动检查总是展示。
                if !userInitiated, preferences.skippedVersion == latest.version.description {
                    state = .upToDate
                } else {
                    state = .available(latest)
                }
            } else {
                state = .upToDate
            }
        } catch {
            Log.update.error("check failed: \(Self.describe(error), privacy: .public)")
            if userInitiated {
                state = .failed(L10n.sf("update.error.check_failed", Self.describe(error)))
            } else {
                state = previous == .checking ? .idle : previous
            }
        }
    }

    /// 跳过当前提示的版本。
    func skipAvailableVersion() {
        guard let release = availableRelease, !isBusy else { return }
        preferences.skippedVersion = release.version.description
        state = .upToDate
    }

    /// 清除失败提示。
    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    // MARK: - 更新

    /// 下载、校验并安装当前可用版本，完成后自动重启。
    func installAvailableUpdate() {
        guard case .available(let release) = state, installTask == nil else { return }
        manualInstallURL = nil
        preferences.skippedVersion = nil
        installTask = Task { [weak self] in
            await self?.performInstall(release)
            self?.installTask = nil
        }
    }

    /// 取消下载 / 校验（安装脚本已启动后不可取消）。
    func cancelInstall() {
        installTask?.cancel()
    }

    private func performInstall(_ release: ReleaseInfo) async {
        do {
            let blocker = UpdateInstaller.inPlaceInstallBlocker(for: bundleURL)
            let app = try await downloadAndUnpack(release)
            if let blocker {
                // 不能原地替换：新版已下载好，引导用户在 Finder 里手动换。
                manualInstallURL = app
                state = .failed(L10n.sf("update.error.manual_install", blocker))
                return
            }
            state = .installing(release)
            try installer.launchInstaller(
                newApp: app, destination: bundleURL, pid: processID, logURL: installLogURL,
                relaunch: relaunchAfterInstall)
            // 给安装脚本一点启动时间，再退出让它接管。
            try? await Task.sleep(for: .milliseconds(400))
            terminate()
        } catch is CancellationError {
            state = .available(release)
        } catch {
            Log.update.error("install failed: \(Self.describe(error), privacy: .public)")
            state = .failed(Self.describe(error))
        }
    }

    private func downloadAndUnpack(_ release: ReleaseInfo) async throws -> URL {
        state = .downloading(release, progress: 0)
        // 回调来自网络线程：按 1% 节流再切回主线程，避免高速下载时刷爆主队列。
        let lastReported = OSAllocatedUnfairLock(initialState: 0.0)
        let zip = try await installer.download(release) { [weak self] value in
            let shouldReport = lastReported.withLock { last -> Bool in
                guard value - last >= 0.01 || value >= 1 else { return false }
                last = value
                return true
            }
            guard shouldReport else { return }
            Task { @MainActor in
                guard let self, case .downloading(let r, _) = self.state else { return }
                self.state = .downloading(r, progress: value)
            }
        }
        try Task.checkCancellation()
        state = .verifying(release)
        let requirement = await UpdateInstaller.designatedRequirement(of: bundleURL)
        if requirement == nil {
            Log.update.notice("current app has no stable signing identity; skipping requirement check")
        }
        return try await installer.unpack(
            zip: zip, release: release, bundleIdentifier: bundleIdentifier, requirement: requirement)
    }

    private nonisolated static func isProgressOnly(_ old: UpdateState, _ new: UpdateState) -> Bool {
        if case .downloading = old, case .downloading = new { return true }
        return false
    }

    /// 错误转为用户可读的描述。
    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? UpdateError { return e.errorDescription ?? error.localizedDescription }
        return error.localizedDescription
    }
}
