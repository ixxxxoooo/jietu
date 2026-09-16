import AppKit
import CoreGraphics

/// 「屏幕录制」权限。
///
/// 参考项目的做法：**每次现读活值，不做启动时快照**；界面轮询 + 用户主动「重新检测」，
/// 并给出明确的「去授权」入口。屏幕录制还多一层 macOS 限制：
/// **授权只在授权之后启动的进程里生效**，所以「已授权但要重启」是独立的一种状态。
///
/// @author ixxxxoooo
enum ScreenCapturePermission {
    /// 进程启动那一刻的授权状态，由 `AppDelegate` 在启动流程最前面记录一次。
    ///
    /// 用它判断「授权是不是发生在本次启动之后」——那正是需要重启的情况。
    private(set) static var wasGrantedAtLaunch = false

    /// 由启动流程最先调用一次（必须是第一件事，否则会被别处的读取抢先）。
    static func recordLaunchState() {
        wasGrantedAtLaunch = isGranted
    }

    /// 现读，不缓存。
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 授权晚于本次启动：已勾选，但当前进程还不能用，必须重启。
    static var needsRelaunch: Bool {
        !wasGrantedAtLaunch && isGranted
    }

    /// 向系统申请一次。已经问过 / 被拒过的，这里不会再弹窗而是直接返回 false。
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// ScreenCaptureKit 在用户授权的那个进程里不会生效，必须重启进程才能开始工作。
    static func relaunchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try task.run()
        } catch {
            NSLog("[Jietu] relaunch failed: \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}
