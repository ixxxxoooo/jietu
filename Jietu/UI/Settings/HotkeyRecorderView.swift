import AppKit
import SwiftUI

/// 设置页里的快捷键录制器。
///
/// **一个控件就是一个完整组件**：点击进入录制、按下组合键写入、悬停时右侧浮出清除，
/// 不再单独摆一个「清除」按钮（参考项目的 `ShortcutRecorder` 也是同一个组件干这两件事）。
///
/// 靠**本地**事件监视器抓 `keyDown`：只在 Jietu 自己的窗口拿到焦点时生效，
/// 不像全局监视器那样需要「辅助功能」权限，也不会偷录其它 App 的输入。
///
/// 默认不设热键（`hotkey == nil` 显示「未设置」）；编辑态下 Esc 取消。
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
    @State private var hovered = false
    /// 录制失败（没按修饰键）时的提示。
    @State private var hint: String?

    var body: some View {
        SettingsRow(
            title: title,
            subtitle: statusText,
            subtitleLineLimit: 1,
            subtitleTint: hint == nil ? nil : Theme.Colors.warning
        ) {
            recorder
        }
        .onDisappear { stopRecording() }
    }

    /// 固定宽高的录制器：组合键长短变化不会让这一列的对齐跑掉。
    private var recorder: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous)
        return content
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(
                width: Theme.Size.shortcutRecorder,
                height: Theme.Size.shortcutRecorderHeight
            )
            .background(shape.fill(Theme.Colors.cardFill).opacity(showsFill ? 1 : 0))
            .overlay(
                shape.strokeBorder(
                    isRecording ? Theme.Colors.accent : Theme.Colors.cardStroke,
                    lineWidth: Theme.Size.hairline
                )
            )
            // 组合键过长时截断，而不是把控件撑大。
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture { startRecording() }
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: Theme.Duration.hover), value: hovered)
    }

    /// 未绑定、未录制、也没悬停时收起底色：一排相同的空槽会比内容本身还响。
    private var showsFill: Bool {
        hotkey != nil || isRecording || hovered
    }

    @ViewBuilder
    private var content: some View {
        if isRecording {
            Text("请按组合键…")
                .font(Theme.Typography.keyCap)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(maxWidth: .infinity)
        } else if let bound = hotkey {
            HStack(spacing: Theme.Spacing.xxs) {
                ForEach(Array(bound.keycaps.enumerated()), id: \.offset) { _, cap in
                    Text(cap)
                        .font(Theme.Typography.keyCap)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .frame(
                            minWidth: Theme.Size.recorderKeyCap,
                            minHeight: Theme.Size.recorderKeyCap
                        )
                        .background(
                            RoundedRectangle(
                                cornerRadius: Theme.Radius.recorderKeyCap, style: .continuous
                            )
                            .fill(Theme.Colors.controlSurface)
                        )
                }
            }
            .frame(maxWidth: .infinity)
            // 覆盖而不是并排：清除按钮不该占掉按键芯片的宽度。
            .overlay(alignment: .trailing) {
                Button {
                    hotkey = nil
                    hint = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .help("清除")
            }
        } else {
            Text("未设置")
                .font(Theme.Typography.keyCap)
                .foregroundStyle(hovered ? Theme.Colors.textSecondary : Theme.Colors.textTertiary)
                .frame(maxWidth: .infinity)
        }
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
