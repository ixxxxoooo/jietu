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
