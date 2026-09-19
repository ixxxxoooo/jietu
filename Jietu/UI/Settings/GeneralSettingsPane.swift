import AppKit
import Combine
import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.launchAtLogin) {
                    Text("登录时启动")
                    Text("开机后自动启动 Jietu，随菜单栏常驻。")
                }
                Toggle(isOn: $settings.playShutterSound) {
                    Text("截图后播放快门音")
                    Text("截图成功时播放系统快门声。")
                }
                Toggle(isOn: $settings.copyToClipboard) {
                    Text("截图后自动复制到剪贴板")
                    Text("截图后立即写入剪贴板，可直接粘贴。")
                }
                Toggle(isOn: $settings.showSaveNotification) {
                    Text("保存后显示系统通知")
                    Text("保存到磁盘后弹出通知，点击可定位文件。")
                }
            } header: {
                SettingsSectionHeader(title: "通用")
            } footer: {
                Text("这些是每次截图都会用到的默认行为。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                } label: {
                    Text("主题")
                    Text("跟随系统，或把 Jietu 固定为浅色 / 深色。")
                }
                .onChange(of: settings.appearance) { _, newValue in
                    newValue.apply()
                }
            } header: {
                SettingsSectionHeader(title: "外观")
            }
        }
        .formStyle(.grouped)
    }
}

/// 录屏：系统音频 / 帧率 / 保存位置。
///
/// 保存位置与截图共用（`saveDirectory`）——录下来的东西和截图落在一起最省心。
///
/// @author ixxxxoooo
