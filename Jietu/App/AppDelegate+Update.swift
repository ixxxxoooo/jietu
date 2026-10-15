import AppKit

/// 在线更新的装配：退出钩子、自动检查、菜单「检查更新…」。
///
/// 流程本身在 `Core/Update/UpdateManager`，这里只负责把它接进 App 生命周期。
extension AppDelegate {
    /// DEBUG 端到端验证：启动后立刻检查并安装更新（配合 `LUCENT_UPDATE_API` 指向本地假发布）。
    static let updateNowFlag = "--update-now"

    /// 在启动时调用一次。
    func setUpUpdates() {
        updates.terminate = { NSApp.terminate(nil) }
        // Dev 渠道不自动检查（本地构建没有对应的发布包）；设了 `LUCENT_UPDATE_API` 则视为有意测试。
        let overridden = ProcessInfo.processInfo.environment[UpdateChecker.apiOverrideEnvironmentKey] != nil
        if !AppIdentity.isDevChannel || overridden {
            updates.startAutoCheck()
        }
    }

    /// 菜单「检查更新…」：把设置窗口切到「关于」，并发起一次手动检查。
    func checkForUpdates() {
        showSettings(section: .about)
        guard !updates.isBusy else { return }
        // 已经发现新版本时，直接停在那张卡片上让用户决定，不再重新请求。
        if updates.availableRelease != nil { return }
        Task { await updates.check(userInitiated: true) }
    }

    #if DEBUG
    /// `--update-now`：检查 → 有新版就直接安装并重启，结果写进日志。
    ///
    /// 安装成功由 `terminate` 钩子退出；走到失败态说明被校验拦下了，同样收工（`Scripts/e2e-update.sh` 靠这点判断）。
    func runUpdateNow() {
        updates.terminate = { NSApp.terminate(nil) }
        Task {
            await updates.check(userInitiated: true)
            guard case .available = updates.state else {
                Log.update.error("--update-now: no update available, state=\(self.updates.state.logDescription, privacy: .public)")
                NSApp.terminate(nil)
                return
            }
            updates.installAvailableUpdate()
            while true {
                try? await Task.sleep(for: .milliseconds(200))
                if case .failed = updates.state {
                    Log.update.error("--update-now: install rejected, state=\(self.updates.state.logDescription, privacy: .public)")
                    NSApp.terminate(nil)
                    return
                }
            }
        }
    }
    #endif
}
