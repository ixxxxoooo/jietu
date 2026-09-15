import AppKit
import SwiftUI

/// 偏好设置主界面：快捷键、截图后行为、保存位置。
///
/// @author ixxxxoooo
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    /// 热键改变时通知外部重新注册（Carbon 热键不能原地改，只能注销再注册）。
    var onHotkeyChange: (Hotkey) -> Void

    var body: some View {
        Form {
            Section("快捷键") {
                HotkeyRecorderView(hotkey: $settings.hotkeyAreaCapture)
            }

            Section("截图后") {
                Toggle("复制到剪贴板", isOn: $settings.copyToClipboard)
                Toggle("播放快门音", isOn: $settings.playShutterSound)
                Toggle("自动保存到磁盘", isOn: $settings.saveToDisk)
                Picker("预览自动关闭", selection: $settings.quickAccessAutoCloseDelay) {
                    Text("1 秒").tag(TimeInterval(1))
                    Text("3 秒").tag(TimeInterval(3))
                    Text("5 秒").tag(TimeInterval(5))
                    Text("10 秒").tag(TimeInterval(10))
                    Text("30 秒").tag(TimeInterval(30))
                    Text("60 秒").tag(TimeInterval(60))
                    Text("永不").tag(TimeInterval(0))
                }
                Picker("预览位置", selection: $settings.quickAccessPosition) {
                    ForEach(QuickAccessPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                saveDirectoryRow
                Picker("保存格式", selection: $settings.saveFormat) {
                    ForEach(SaveFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                HStack(spacing: 12) {
                    Text("JPEG 质量")
                        .font(.system(size: 13))
                    Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                        .frame(maxWidth: 200)
                    Text(String(format: "%.0f%%", settings.jpegQuality * 100))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Spacer(minLength: 0)
                }
                .disabled(settings.saveFormat != .jpeg)
                .opacity(settings.saveFormat == .jpeg ? 1 : 0.5)
            }

            Section("通用") {
                Toggle("登录时启动", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 500)
        .onChange(of: settings.hotkeyAreaCapture) { _, newValue in
            onHotkeyChange(newValue)
        }
        .onChange(of: settings.launchAtLogin) { _, newValue in
            LaunchAtLogin.setEnabled(newValue)
        }
    }

    private var saveDirectoryRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("保存位置")
                    .font(.system(size: 13))
                Text(settings.saveDirectory.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("选择…") { chooseDirectory() }
                .disabled(!settings.saveToDisk)
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([settings.saveDirectory])
            }
            .disabled(!settings.saveToDisk)
        }
    }

    /// 打开目录选择器，选定后写回 `SettingsStore`。
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url
        }
    }
}
