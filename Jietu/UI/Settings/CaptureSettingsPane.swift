import AppKit
import Combine
import SwiftUI

struct CaptureSettingsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.saveToDisk) {
                    Text(L10n.captureSaveToDisk)
                    Text(L10n.captureSaveToDiskDesc)
                }
                LabeledContent {
                    HStack(spacing: Theme.Spacing.md) {
                        Button(L10n.captureChoose) { chooseDirectory() }
                        Button(L10n.captureRevealInFinder) {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.saveDirectory])
                        }
                    }
                } label: {
                    Text(L10n.captureSaveLocation)
                    Text(settings.saveDirectory.path)
                }
                .settingsEnabled(settings.saveToDisk)
            } header: {
                SettingsSectionHeader(title: L10n.captureSectionOutput)
            }

            Section {
                Picker(selection: $settings.saveFormat) {
                    ForEach(SaveFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                } label: {
                    Text(L10n.captureSaveFormat)
                    Text(L10n.captureSaveFormatDesc)
                }

                SettingsRow(title: L10n.captureJpegQuality, subtitle: L10n.captureJpegQualityDesc) {
                    Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                        .frame(width: 180)
                    Text(String(format: "%.0f%%", settings.jpegQuality * 100))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .settingsEnabled(settings.saveFormat == .jpeg)
            } header: {
                SettingsSectionHeader(title: L10n.captureSectionFormat)
            }

            Section {
                SettingsRow(
                    title: L10n.captureFilenameTemplate,
                    subtitle: L10n.captureFilenameHint(FilenameTemplate.placeholderHint, previewFilename),
                    subtitleLineLimit: 3
                ) {
                    TextField(FilenameTemplate.defaultTemplate, text: $settings.filenameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Button(L10n.captureResetDefault) {
                        settings.filenameTemplate = FilenameTemplate.defaultTemplate
                    }
                }
            } header: {
                SettingsSectionHeader(title: L10n.captureSectionNaming)
            }

            Section {
                Toggle(isOn: $settings.windowShadowEnabled) {
                    Text(L10n.captureWindowShadow)
                    Text(L10n.captureWindowShadowDesc)
                }
                SettingsRow(
                    title: L10n.captureShadowSize,
                    subtitle: L10n.captureShadowSizeDesc
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
                SettingsSectionHeader(title: L10n.captureSectionWindowCapture)
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
        panel.prompt = L10n.captureChoose
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url
        }
    }
}

/// 快捷键：每个动作一行，尾部是录制器。
///
/// @author ixxxxoooo
