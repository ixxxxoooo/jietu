import AppKit
import SwiftUI

/// 保存面板（`NSSavePanel`）下方的 GIF 导出参数微调面板。
///
/// 允许用户在选保存路径的同时即时确认并调整尺寸、帧率与画质，与 `SettingsStore` 双向绑定。
///
/// @author ixxxxoooo
struct GifExportAccessoryView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(L10n.recordingGifAccessoryTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.md, verticalSpacing: Theme.Spacing.xs) {
                GridRow {
                    Text(L10n.recordingGifResolution)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settings.gifResolution) {
                        ForEach(GifResolution.allCases) { res in
                            Text(res.title).tag(res)
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    Text(L10n.recordingGifFrameRate)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settings.gifFrameRate) {
                        Text("10 fps").tag(10)
                        Text("15 fps").tag(15)
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                    }
                    .labelsHidden()
                }

                GridRow {
                    Text(L10n.recordingGifQuality)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settings.gifQuality) {
                        ForEach(GifQuality.allCases) { q in
                            Text(q.title).tag(q)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }
}
