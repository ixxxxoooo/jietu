import Foundation

/// 可绑定全局热键的动作。
///
/// 每个动作一组默认组合键，用户可在设置页逐一改写；改完由 AppDelegate
/// 注销旧键、注册新键。
///
/// @author ixxxxoooo
enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case areaCapture
    case windowCapture
    case fullScreenCapture
    case timedCapture
    case scrollingCapture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .areaCapture: return "区域截图"
        case .windowCapture: return "窗口截图"
        case .fullScreenCapture: return "全屏截图"
        case .timedCapture: return "定时截图"
        case .scrollingCapture: return "滚动长图"
        }
    }

    /// 设置页里的说明文案。
    var subtitle: String {
        switch self {
        case .areaCapture: return "拖动选区，截取任意区域"
        case .windowCapture: return "抓取鼠标下方的窗口"
        case .fullScreenCapture: return "抓取鼠标所在的显示器"
        case .timedCapture: return "延时 \(Int(HotkeyAction.timedCaptureDelay)) 秒后进入区域截图"
        case .scrollingCapture: return "框选区域后滚动内容，自动拼成长图"
        }
    }

    /// 定时截图热键使用的延时（秒）。
    static let timedCaptureDelay: TimeInterval = 5

    /// 出厂默认组合键。
    var defaultHotkey: Hotkey {
        switch self {
        case .areaCapture: return .captureArea
        case .windowCapture: return .captureWindow
        case .fullScreenCapture: return .captureFullScreen
        case .timedCapture: return .captureTimed
        case .scrollingCapture: return .captureScrolling
        }
    }
}
