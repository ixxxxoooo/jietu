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
                    Text(L10n.annotationEditorMode)
                    Text(L10n.annotationEditorModeDesc)
                }
            } header: {
                SettingsSectionHeader(title: L10n.annotationSectionAnnotation)
            }

            Section {
                SettingsRow(title: L10n.annotationDefaultStyle, subtitle: styleSummary) {
                    Button(L10n.captureResetDefault) { settings.annotationDefaults = .standard }
                }
            } header: {
                SettingsSectionHeader(title: L10n.annotationSectionDefaultStyle)
            } footer: {
                Text(L10n.annotationDefaultStyleFooter)
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
        let colorName = Self.colorNames[color] ?? L10n.colorCustom
        return L10n.annotationStyleSummary(
            style.tool.title, colorName, Int(width), Int(style.fontSize))
    }

    private static let colorNames: [RGBAColor: String] = [
        .red: L10n.colorRed, .orange: L10n.colorOrange, .yellow: L10n.colorYellow,
        .green: L10n.colorGreen,
        .blue: L10n.colorBlue, .white: L10n.colorWhite, .black: L10n.colorBlack,
    ]
}

/// 权限：屏幕录制状态 + 授权对象 + 授权操作。
///
/// 状态字形放在**尾部**（和参考项目一致），标题那侧只放文字。
/// 状态是**现读 + 1 秒轮询**的：用户去系统设置勾完切回来，这里会自己变，
/// 另外给了「重新检测」和「重启 Jietu」两个出口（屏幕录制的授权在授权时的那个进程里不生效）。
///
/// @author ixxxxoooo
