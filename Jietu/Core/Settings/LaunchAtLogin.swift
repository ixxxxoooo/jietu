import Foundation
import ServiceManagement

/// 开机自启（登录项）封装。
///
/// 用 `SMAppService.mainApp`：只对当前 App 生效，无需额外 helper bundle，
/// 也不需要用户手动去「登录项」里添加。
///
/// @author ixxxxoooo
enum LaunchAtLogin {
    /// 应用当前开关状态。失败只记日志——自启不是关键路径，
    /// 不应因为系统拒绝而打断用户的截图流程。
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[Jietu] launch at login \(enabled) failed: \(error.localizedDescription)")
        }
    }
}
