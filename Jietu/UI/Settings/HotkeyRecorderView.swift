import AppKit
import SwiftUI

/// 设置页里的组合键录制控件。
///
/// 靠**本地**事件监视器抓 `keyDown`：只在 Jietu 自己的窗口拿到焦点时生效，
/// 不像全局监视器那样需要「辅助功能」权限，也不会偷录其它 App 的输入。
///
/// 默认不设热键（`hotkey == nil` 显示「未设置」），录制后可再点「清除」删掉。
/// 视觉走 Tinycast 的设置行：标题 + 副标题 + 尾部 keycap / 玻璃按钮。
///
/// @author ixxxxoooo
struct HotkeyRecorderView: View {
    /// 动作名，例如「区域截图」。
    var title: String
    /// 未录制时展示的说明文案。
    var subtitle: String
    /// 行首图标的 SF Symbol。
    var icon: String = "keyboard"
    /// 行首图标主题色，与所在设置分区一致。
    var tint: Color = Theme.Colors.textSecondary
    @Binding var hotkey: Hotkey?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        SettingsRow(
            title: title,
            subtitle: statusText,
            subtitleLineLimit: 1,
            subtitleTint: hint == nil ? nil : Theme.Colors.warning,
            icon: { SettingsIcon(systemImage: icon, tint: tint) }
        ) {
            HStack(spacing: Theme.Spacing.md) {
                if isRecording {
                    Text("录制中…")
                        .font(Theme.Typography.bar)
                        .foregroundStyle(Theme.Colors.brand)
                    Button("取消") { stopRecording() }
                        .buttonStyle(.link)
                } else {
                    Button {
                        startRecording()
                    } label: {
                        KeyCapChip(
                            text: hotkey?.displayString ?? "未设置",
                            style: .filled,
                            scale: .standard
                        )
                    }
                    .buttonStyle(.plain)
                    .help("点击后按下新的组合键")

                    Button("清除") {
                        hotkey = nil
                        hint = nil
                    }
                    .buttonStyle(.link)
                    .disabled(hotkey == nil)
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private var statusText: String {
        if isRecording { return "请按下新的组合键，Esc 取消" }
        return hint ?? subtitle
    }

    /// 进入录制态并挂上本地事件监视器。
    private func startRecording() {
        guard !isRecording else { return }
        hint = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc 退出录制，避免用户被困在录制态里。
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let recorded = Hotkey.from(event: event) else {
                hint = "至少需要一个修饰键（⌘ ⌥ ⌃ ⇧）"
                return nil
            }
            hint = nil
            hotkey = recorded
            stopRecording()
            return nil
        }
    }

    /// 退出录制态并移除监视器（幂等）。
    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }
}
