import AppKit
import SwiftUI

/// 快捷键录制芯片：**一个控件就是一个完整组件**——点击进入录制、按下组合键写入、
/// 悬停时右侧浮出清除（对齐参考项目的 `ShortcutRecorder`）。
///
/// 靠**本地**事件监视器抓 `keyDown`：只在 Jietu 自己的窗口拿到焦点时生效，
/// 不像全局监视器那样需要「辅助功能」权限，也不会偷录其它 App 的输入。
///
/// 固定宽高：组合键长短变化不会让这一列的对齐跑掉。编辑态下 Esc 取消。
///
/// @author ixxxxoooo
struct HotkeyRecorderChip: View {
    @Binding var hotkey: Hotkey?
    /// 录制失败（没按修饰键）时回报一句提示，由宿主行的副标题展示。
    var onHint: ((String?) -> Void)?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hovered = false
    @State private var hint: String?

    var body: some View {
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
            .onDisappear { stopRecording() }
    }

    /// 未绑定、未录制、也没悬停时收起底色：一排相同的空槽会比内容本身还响。
    private var showsFill: Bool {
        hotkey != nil || isRecording || hovered
    }

    @ViewBuilder
    private var content: some View {
        if isRecording {
            Text(L10n.hotkeyRecorderPlaceholder)
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
                    setHint(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .help(L10n.hotkeyRecorderClear)
            }
        } else {
            Text(L10n.hotkeyRecorderNotSet)
                .font(Theme.Typography.keyCap)
                .foregroundStyle(hovered ? Theme.Colors.textSecondary : Theme.Colors.textTertiary)
                .frame(maxWidth: .infinity)
        }
    }

    /// 进入录制态并挂上本地事件监视器。
    private func startRecording() {
        guard !isRecording else { return }
        setHint(nil)
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc 退出录制，避免用户被困在录制态里。
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let recorded = Hotkey.from(event: event) else {
                setHint(L10n.hotkeyRecorderNeedModifier)
                return nil
            }
            setHint(nil)
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

    private func setHint(_ text: String?) {
        hint = text
        onHint?(text)
    }
}

/// 设置页里的快捷键录制行：标题 / 副标题 + 尾部录制芯片。
///
/// @author ixxxxoooo
struct HotkeyRecorderView: View {
    /// 动作名，例如「区域截图」。
    var title: String
    /// 未录制时展示的说明文案。
    var subtitle: String
    @Binding var hotkey: Hotkey?

    @State private var hint: String?

    var body: some View {
        SettingsRow(
            title: title,
            subtitle: hint ?? subtitle,
            subtitleLineLimit: 1,
            subtitleTint: hint == nil ? nil : Theme.Colors.warning
        ) {
            HotkeyRecorderChip(hotkey: $hotkey) { newHint in
                hint = newHint
            }
        }
    }
}
