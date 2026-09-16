import CoreGraphics
import Foundation

enum CaptureError: LocalizedError {
    case permissionDenied
    case noShareableContent(String)
    case noDisplays
    case displayNotShareable(CGDirectDisplayID)
    case emptyImage(CGDirectDisplayID)
    case emptyRegion
    case windowNotCapturable(CGWindowID)
    case noWindowUnderCursor

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "未获得「屏幕录制」权限"
        case .noShareableContent(let detail):
            return "无法获取可捕获的屏幕内容：\(detail)"
        case .noDisplays:
            return "没有找到可捕获的显示器"
        case .displayNotShareable(let id):
            return "显示器 \(id) 当前不可捕获"
        case .emptyImage(let id):
            return "显示器 \(id) 返回了空图像"
        case .emptyRegion:
            return "选区太小，无法截取"
        case .windowNotCapturable(let id):
            return "窗口 \(id) 当前不可捕获"
        case .noWindowUnderCursor:
            return "鼠标下没有可截取的窗口"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "请在「系统设置 › 隐私与安全性 › 屏幕录制」中勾选 Jietu，然后重启 Jietu。"
        case .noShareableContent, .displayNotShareable, .emptyImage, .windowNotCapturable:
            return "通常是权限刚授予但进程尚未重启，请重启 Jietu 后重试。"
        case .noDisplays:
            return "请确认显示器已正确连接。"
        case .emptyRegion:
            return "请框选一块更大一点的区域再试。"
        case .noWindowUnderCursor:
            return "请把鼠标移到要截取的窗口上再试一次。"
        }
    }

    /// 这类失败重启一下基本就好（屏幕录制的授权在授权时的那个进程里不生效）。
    var suggestsRelaunch: Bool {
        switch self {
        case .permissionDenied, .noShareableContent, .displayNotShareable, .emptyImage,
            .windowNotCapturable:
            return true
        case .noDisplays, .emptyRegion, .noWindowUnderCursor:
            return false
        }
    }
}
