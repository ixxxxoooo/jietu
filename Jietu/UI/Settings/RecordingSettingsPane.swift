import AppKit
import Combine
import SwiftUI

struct RecordingSettingsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.recordSystemAudio) {
                    Text(L10n.recordingSystemAudio)
                    Text(L10n.recordingSystemAudioDesc)
                }
                Toggle(isOn: $settings.recordMicrophone) {
                    Text(L10n.recordingMicrophone)
                    Text(L10n.recordingMicrophoneDesc)
                }
                Picker(selection: $settings.recordFrameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                } label: {
                    Text(L10n.recordingFrameRate)
                    Text(L10n.recordingFrameRateDesc)
                }
            } header: {
                SettingsSectionHeader(title: L10n.recordingSectionRecording)
            }

            Section {
                Picker(selection: $settings.gifResolution) {
                    ForEach(GifResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                } label: {
                    Text(L10n.recordingGifResolution)
                    Text(L10n.recordingGifResolutionDesc)
                }

                Picker(selection: $settings.gifFrameRate) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                } label: {
                    Text(L10n.recordingGifFrameRate)
                    Text(L10n.recordingGifFrameRateDesc)
                }

                Picker(selection: $settings.gifQuality) {
                    ForEach(GifQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                } label: {
                    Text(L10n.recordingGifQuality)
                    Text(L10n.recordingGifQualityDesc)
                }
            } header: {
                SettingsSectionHeader(title: L10n.recordingSectionGif)
            }

            Section {
                LabeledContent {
                    Button(L10n.captureRevealInFinder) {
                        NSWorkspace.shared.activateFileViewerSelecting([settings.saveDirectory])
                    }
                } label: {
                    Text(L10n.recordingSaveLocation)
                    Text(settings.saveDirectory.path)
                }
            } header: {
                SettingsSectionHeader(title: L10n.recordingSectionOutput)
            } footer: {
                Text(L10n.recordingOutputFooter)
            }
        }
        .formStyle(.grouped)
    }
}

/// 截图：保存位置 / 格式 / 命名。
///
/// @author ixxxxoooo
