import AppKit
import Combine
import SwiftUI

struct AnnotationSettingsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.editorMode) {
                    ForEach(EditorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    Text("截选后流程")
                    Text("立即标注：截完直接在当前画面上标注。\n浮窗预览：截完先显示浮窗，点开后居中原地编辑。")
                }
            } header: {
                SettingsSectionHeader(title: "标注")
            }

            Section {
                SettingsRow(title: "默认样式", subtitle: styleSummary) {
                    Button("恢复默认") { settings.annotationDefaults = .standard }
                }
            } header: {
                SettingsSectionHeader(title: "默认样式")
            } footer: {
                Text("工具 / 颜色 / 参数沿用上次用法。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var styleSummary: String {
        let style = settings.annotationDefaults
        // 高亮笔有独立色槽与笔尖粗细，摘要得跟着它走，否则显示的是画笔的那套。
        let isMarker = style.tool == .highlight
        let color = isMarker ? style.highlightColor : style.color
        let width = isMarker ? style.highlightLineWidth : style.lineWidth
        let colorName = Self.colorNames[color] ?? "自定义色"
        return "\(style.tool.title) · \(colorName) · 线宽 \(Int(width)) · 字号 \(Int(style.fontSize))"
    }

    private static let colorNames: [RGBAColor: String] = [
        .red: "红", .orange: "橙", .yellow: "黄", .green: "绿",
        .blue: "蓝", .white: "白", .black: "黑",
    ]
}

/// 权限：屏幕录制状态 + 授权对象 + 授权操作。
///
/// 状态字形放在**尾部**（和参考项目一致），标题那侧只放文字。
/// 状态是**现读 + 1 秒轮询**的：用户去系统设置勾完切回来，这里会自己变，
/// 另外给了「重新检测」和「重启 Jietu」两个出口（屏幕录制的授权在授权时的那个进程里不生效）。
///
/// @author ixxxxoooo
