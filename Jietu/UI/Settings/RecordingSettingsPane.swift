import AppKit
import Combine
import SwiftUI

struct RecordingSettingsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.recordSystemAudio) {
                    Text("录制系统声音")
                    Text("把页面里的视频 / 音乐一起录进去。")
                }
                Toggle(isOn: $settings.recordMicrophone) {
                    Text("录制麦克风")
                    Text("录下讲解旁白，与系统声音混成一条音轨；首次开启会请求麦克风权限。")
                }
                Picker(selection: $settings.recordFrameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                } label: {
                    Text("帧率")
                    Text("60 更顺滑，文件也更大。")
                }
            } header: {
                SettingsSectionHeader(title: "录制")
            }

            Section {
                LabeledContent {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([settings.saveDirectory])
                    }
                } label: {
                    Text("保存位置")
                    Text(settings.saveDirectory.path)
                }
            } header: {
                SettingsSectionHeader(title: "输出")
            } footer: {
                Text("录屏保存为 mp4（H.264），与截图共用上面的位置与命名模板。")
            }
        }
        .formStyle(.grouped)
    }
}

/// 截图：保存位置 / 格式 / 命名。
///
/// @author ixxxxoooo
