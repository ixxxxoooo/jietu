import AppKit
import SwiftUI

/// 设置页里的组合键录制控件。
///
/// 靠**本地**事件监视器抓 `keyDown`：只在 Jietu 自己的窗口拿到焦点时生效，
/// 不像全局监视器那样需要「辅助功能」权限，也不会偷录其它 App 的输入。
///
/// 默认不设热键（`hotkey == nil` 显示「未设置」），录制后可再点「清除」删掉。
///
/// @author ixxxxoooo
struct HotkeyRecorderView: View {
    /// 动作名，例如「区域截图」。
    var title: String
    /// 未录制时展示的说明文案。
    var subtitle: String
    @Binding var hotkey: Hotkey?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(hint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            }
            Spacer(minLength: 12)

            if isRecording {
                Text("录制中…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.brand)
                Button("取消") { stopRecording() }
                    .buttonStyle(.link)
            } else {
                Button(hotkey?.displayString ?? "未设置") { startRecording() }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .frame(minWidth: 88)
                Button("清除") {
                    hotkey = nil
                    hint = nil
                }
                .buttonStyle(.link)
                .disabled(hotkey == nil)
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
