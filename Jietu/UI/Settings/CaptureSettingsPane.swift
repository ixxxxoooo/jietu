import AppKit
import Combine
import SwiftUI

struct CaptureSettingsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.saveToDisk) {
                    Text("自动保存到磁盘")
                    Text("截图后自动写入下面选定的保存位置。")
                }
                LabeledContent {
                    HStack(spacing: Theme.Spacing.md) {
                        Button("选择…") { chooseDirectory() }
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.saveDirectory])
                        }
                    }
                } label: {
                    Text("保存位置")
                    Text(settings.saveDirectory.path)
                }
                .settingsEnabled(settings.saveToDisk)
            } header: {
                SettingsSectionHeader(title: "输出")
            }

            Section {
                Picker(selection: $settings.saveFormat) {
                    ForEach(SaveFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                } label: {
                    Text("保存格式")
                    Text("PNG 无损体积大，JPEG 可调质量。")
                }

                SettingsRow(title: "JPEG 质量", subtitle: "只在 JPEG 格式下生效。") {
                    Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                        .frame(width: 180)
                    Text(String(format: "%.0f%%", settings.jpegQuality * 100))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .settingsEnabled(settings.saveFormat == .jpeg)
            } header: {
                SettingsSectionHeader(title: "格式")
            }

            Section {
                SettingsRow(
                    title: "文件名模板",
                    subtitle: "\(FilenameTemplate.placeholderHint)\n示例：\(previewFilename)",
                    subtitleLineLimit: 3
                ) {
                    TextField(FilenameTemplate.defaultTemplate, text: $settings.filenameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Button("恢复默认") {
                        settings.filenameTemplate = FilenameTemplate.defaultTemplate
                    }
                }
            } header: {
                SettingsSectionHeader(title: "命名")
            }

            Section {
                Toggle(isOn: $settings.windowShadowEnabled) {
                    Text("窗口截图阴影")
                    Text("点选窗口截图时自动裁出圆角，并加上 macOS 风格的拟物投影。")
                }
                SettingsRow(
                    title: "阴影大小",
                    subtitle: "数值越大投影越柔和、扩散越远，窗口看起来悬浮得越高。"
                ) {
                    HStack(spacing: Theme.Spacing.md) {
                        Slider(
                            value: $settings.windowShadowSize,
                            in: 16...64,
                            step: 4
                        )
                        .frame(width: 140)
                        Text("\(Int(settings.windowShadowSize)) pt")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .settingsEnabled(settings.windowShadowEnabled)
            } header: {
                SettingsSectionHeader(title: "窗口截图")
            }
        }
        .formStyle(.grouped)
    }

    /// 用当前模板与当前时刻给出一个文件名示例。
    private var previewFilename: String {
        let name = FilenameTemplate.makeName(
            template: settings.effectiveFilenameTemplate,
            date: Date(),
            counter: FilenameTemplate.usesCounter(settings.effectiveFilenameTemplate) ? 1 : 0
        )
        return "\(name).\(settings.saveFormat.fileExtension)"
    }

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

/// 快捷键：每个动作一行，尾部是录制器。
///
/// @author ixxxxoooo
