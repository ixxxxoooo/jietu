import AppKit
import SwiftUI

/// 关于：hero（图标 / 名称 / 版本 / 一句话）+ 信息行 + 底部版权。
///
/// 排版照参考项目的 About：hero 在 Form 的第一张卡片里居中，
/// 版本号用 `cardFill` 药丸，底部版权放在 Form **外面**、钉在窗口下沿。
///
/// @author ixxxxoooo
struct AboutSettingsPane: View {
    private static let iconSize: CGFloat = 88

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "版本 \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    hero
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.lg)
                }

                Section {
                    LabeledContent("构建渠道") {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(AppIdentity.isDevChannel ? "Debug" : "Release")
                            if AppIdentity.isDevChannel {
                                DevChannelBadge()
                            }
                        }
                    }
                    LabeledContent("Bundle ID") {
                        Text(AppIdentity.bundleIdentifier)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("屏幕录制") {
                        Label(
                            ScreenCapturePermission.isGranted ? "已授权" : "未授权",
                            systemImage: ScreenCapturePermission.isGranted
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(
                            ScreenCapturePermission.isGranted ? Color.green : Color.orange)
                    }
                } header: {
                    SettingsSectionHeader(title: "信息")
                }
            }
            .formStyle(.grouped)

            // 放在 Form 外面，版权才钉在窗口下沿。
            footer
                .padding(.bottom, Theme.Spacing.xxl)
        }
    }

    private var hero: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

            VStack(spacing: Theme.Spacing.sm) {
                Text(AppIdentity.displayName)
                    .font(.title.weight(.bold))
                Text(Self.version)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xs / 2)
                    .background(Capsule().fill(Theme.Colors.cardFill))
                    .overlay(Capsule().strokeBorder(Theme.Colors.cardStroke, lineWidth: 1))
            }

            Text("本机截图工具：截完即标注、复制、保存，数据不出本机。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        Text("© 2026 Jietu · 截图与标注全部在本机完成")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}
