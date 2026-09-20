import Carbon.HIToolbox
import Foundation

/// 可绑定全局热键的动作。
///
/// 除 `defaults` 里那几个（区域截图出厂配 ⌃⌘A）之外，其余动作默认**不设**热键
/// （避免和系统 / 其它 App 抢组合键），用户想用哪个就在设置页自己录一个，也可以随时清除。
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

    /// 出厂就配好的全局热键。
    ///
    /// 只给**最常用的一条**（区域截图 ⌃⌘A）：截图工具没有「按一下就能截」的入口太别扭，
    /// 而这个组合键既不在系统快捷键表里，也不常被别的 App 占。
    /// 只对「用户自己没设过这个动作」生效——在设置页清掉之后**不会再填回来**
    /// （见 `SettingsStore.init` 里的一次性补齐）。
    static let defaults: [HotkeyAction: Hotkey] = [
        .areaCapture: Hotkey(
            keyCode: UInt32(kVK_ANSI_A),
            carbonModifiers: UInt32(cmdKey | controlKey)
        )
    ]
}
