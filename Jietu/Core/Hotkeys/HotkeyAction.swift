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
    case windowRecording
    case fullScreenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .areaCapture: return L10n.actionAreaCapture
        case .windowCapture: return L10n.actionWindowCapture
        case .fullScreenCapture: return L10n.actionFullScreenCapture
        case .timedCapture: return L10n.actionTimedCapture
        case .scrollingCapture: return L10n.actionScrollingCapture
        case .screenRecording: return L10n.actionRegionRecording
        case .windowRecording: return L10n.actionWindowRecording
        case .fullScreenRecording: return L10n.actionFullScreenRecording
        }
    }

    /// 设置页里的说明文案。
    var subtitle: String {
        switch self {
        case .areaCapture: return L10n.actionAreaCaptureDesc
        case .windowCapture: return L10n.actionWindowCaptureDesc
        case .fullScreenCapture: return L10n.actionFullScreenCaptureDesc
        case .timedCapture: return L10n.actionTimedCaptureDesc(Int(HotkeyAction.timedCaptureDelay))
        case .scrollingCapture: return L10n.actionScrollingCaptureDesc
        case .screenRecording: return L10n.actionRegionRecordingDesc
        case .windowRecording: return L10n.actionWindowRecordingDesc
        case .fullScreenRecording: return L10n.actionFullScreenRecordingDesc
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
        case .windowRecording: return "macwindow"
        case .fullScreenRecording: return "rectangle.fill"
        }
    }

    /// 定时截图热键使用的延时（秒）。
    static let timedCaptureDelay: TimeInterval = 5
}
