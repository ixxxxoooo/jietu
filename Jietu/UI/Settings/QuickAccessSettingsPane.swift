import AppKit
import Combine
import SwiftUI

struct QuickAccessSettingsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.quickAccessPosition) {
                    ForEach(QuickAccessPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                } label: {
                    Text("停靠位置")
                    Text("截图后浮窗出现在屏幕的哪个角。")
                }

                Picker(selection: $settings.quickAccessAutoCloseDelay) {
                    Text("1 秒").tag(TimeInterval(1))
                    Text("3 秒").tag(TimeInterval(3))
                    Text("5 秒").tag(TimeInterval(5))
                    Text("10 秒").tag(TimeInterval(10))
                    Text("30 秒").tag(TimeInterval(30))
                    Text("60 秒").tag(TimeInterval(60))
                    Text("永不").tag(TimeInterval(0))
                } label: {
                    Text("自动关闭")
                    Text("浮窗多久后自动消失，「永不」则需手动关闭。")
                }
            } header: {
                SettingsSectionHeader(title: "浮窗")
            }
        }
        .formStyle(.grouped)
    }
}

/// 标注：编辑方式 + 默认样式。
///
/// @author ixxxxoooo
