import Foundation

/// 可绑定全局热键的动作。
///
/// 每个动作默认**不设**热键（避免和系统 / 其它 App 抢组合键），
/// 用户想用哪个就在设置页自己录一个，也可以随时清除。
///
/// @author ixxxxoooo
enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case areaCapture
    case windowCapture
    case fullScreenCapture
    case timedCapture
    case scrollingCapture
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .areaCapture: return "区域截图"
        case .windowCapture: return "窗口截图"
        case .fullScreenCapture: return "全屏截图"
        case .timedCapture: return "定时截图"
        case .scrollingCapture: return "滚动长图"
        case .screenRecording: return "录屏"
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
        case .screenRecording: return "框选区域开始录屏，随时暂停 / 完成"
        }
    }

    /// 设置页图标的 SF Symbol。
    var symbol: String {
        switch self {
        case .areaCapture: return "rectangle.dashed"
        case .windowCapture: return "macwindow"
        case .fullScreenCapture: return "rectangle.inset.filled"
        case .timedCapture: return "timer"
        case .scrollingCapture: return "scroll"
        case .screenRecording: return "record.circle"
        }
    }

    /// 定时截图热键使用的延时（秒）。
    static let timedCaptureDelay: TimeInterval = 5
}
