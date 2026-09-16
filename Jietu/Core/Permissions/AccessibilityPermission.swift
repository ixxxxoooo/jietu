import AppKit
import ApplicationServices

/// 「辅助功能」权限。
///
/// 用途：**自动滚动长截图**要合成滚轮事件投给别的 App，没有这个权限时
/// `CGEvent.post` 会静默失败（看起来就是「滚不动」）。
/// 另外权限状态是**现读**的，授予后无需重启（不像屏幕录制）。
///
/// @author ixxxxoooo
enum AccessibilityPermission {
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 申请一次：系统会弹出「…想要控制这台电脑」的引导（只弹一次）。
    @discardableResult
    static func request() -> Bool {
        // 直接用字面量键，避开不同 SDK 下 kAXTrustedCheckOptionPrompt 的类型摩擦。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        PermissionPane.accessibility.openSystemSettings()
    }
}
