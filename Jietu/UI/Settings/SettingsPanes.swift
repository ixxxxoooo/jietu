import AppKit
import Combine
import SwiftUI

// 设置各分区的内容。
//
// 每条设置行都是**系统控件**（`Toggle` / `Picker` / `LabeledContent`），
// label 用两段式：第一段是标题，其余自动成为次级副标题——副标题的字号 / 颜色 /
// 换行都由系统按分区表单的规格给，不自己拼 HStack。
// 只有「尾部是自定义控件」的行（滑块、按钮组、录制器）才用 `SettingsRow`。

/// 通用：默认行为 + 外观。
///
/// @author ixxxxoooo
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

/// 截图：保存位置 / 格式 / 命名。
///
/// @author ixxxxoooo
struct CaptureSettingsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.saveToDisk) {
                    Text("自动保存到磁盘")
                    Text("截图后自动写入下面选定的保存位置。")
                }
                LabeledContent {
                    HStack(spacing: Theme.Spacing.md) {
                        Button("选择…") { chooseDirectory() }
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.saveDirectory])
                        }
                    }
                } label: {
                    Text("保存位置")
                    Text(settings.saveDirectory.path)
                }
                .settingsEnabled(settings.saveToDisk)
            } header: {
                SettingsSectionHeader(title: "输出")
            }

            Section {
                Picker(selection: $settings.saveFormat) {
                    ForEach(SaveFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                } label: {
                    Text("保存格式")
                    Text("PNG 无损体积大，JPEG 可调质量。")
                }

                SettingsRow(title: "JPEG 质量", subtitle: "只在 JPEG 格式下生效。") {
                    Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                        .frame(width: 180)
                    Text(String(format: "%.0f%%", settings.jpegQuality * 100))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .settingsEnabled(settings.saveFormat == .jpeg)
            } header: {
                SettingsSectionHeader(title: "格式")
            }

            Section {
                SettingsRow(
                    title: "文件名模板",
                    subtitle: "\(FilenameTemplate.placeholderHint)\n示例：\(previewFilename)",
                    subtitleLineLimit: 3
                ) {
                    TextField(FilenameTemplate.defaultTemplate, text: $settings.filenameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Button("恢复默认") {
                        settings.filenameTemplate = FilenameTemplate.defaultTemplate
                    }
                }
                .settingsEnabled(settings.saveToDisk)
            } header: {
                SettingsSectionHeader(title: "命名")
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
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url
        }
    }
}

/// 快捷键：每个动作一行，尾部是录制器。
///
/// @author ixxxxoooo
struct HotkeysSettingsPane: View {
    @Bindable var settings: SettingsStore
    var onHotkeyChange: (HotkeyAction, Hotkey?) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HotkeyRecorderView(
                        title: action.title,
                        subtitle: action.subtitle,
                        hotkey: binding(for: action)
                    )
                }
            } header: {
                SettingsSectionHeader(title: "快捷键")
            } footer: {
                Text(
                    "默认都不设置快捷键，点一下录制器再按组合键即可录入；"
                        + "悬停录制器时右侧的 ✕ 可清除。\n"
                        + "全局热键会抢占其它 App 的同名组合键，建议避开常用组合。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for action: HotkeyAction) -> Binding<Hotkey?> {
        Binding(
            get: { settings.hotkey(for: action) },
            set: { newValue in
                settings.setHotkey(newValue, for: action)
                onHotkeyChange(action, newValue)
            }
        )
    }
}

/// 预览浮窗：停靠位置 / 自动关闭。
///
/// @author ixxxxoooo
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
                SettingsSectionHeader(title: "预览浮窗")
            }
        }
        .formStyle(.grouped)
    }
}

/// 标注：编辑方式 + 默认样式。
///
/// @author ixxxxoooo
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
                    Text("编辑方式")
                    Text("原地编辑：截完直接在当前画面上标注。\n独立窗口：截完先显示浮窗，点开后在单独窗口编辑。")
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
        let colorName = Self.colorNames[style.color] ?? "自定义色"
        return "\(style.tool.title) · \(colorName) · 线宽 \(Int(style.lineWidth)) · 字号 \(Int(style.fontSize))"
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
struct PermissionSettingsPane: View {
    @State private var granted = ScreenCapturePermission.isGranted
    @State private var triedGranting = false

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// 授权晚于本次启动，或引导过授权但状态还没变 → 给「重启」。
    private var suggestsRelaunch: Bool {
        ScreenCapturePermission.needsRelaunch || (triedGranting && !granted)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.lg) {
                        Label(
                            granted ? "已授权" : "未授权",
                            systemImage: granted
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(granted ? Color.green : Color.orange)

                        Button("重新检测") { refresh() }
                            .controlSize(.small)
                            .help("立刻再读一次系统里的授权状态")
                    }
                } label: {
                    Text("屏幕录制")
                    Text(
                        granted
                            ? (ScreenCapturePermission.needsRelaunch
                                ? "已经勾选，重启后生效。" : "Jietu 可以正常冻结屏幕并截图。")
                            : "没有它，截图会返回空白画面。"
                    )
                }

                // dev 渠道是独立 bundle id，系统设置里是另一条授权，得让用户知道勾哪个。
                LabeledContent {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(AppIdentity.displayName)
                        if AppIdentity.isDevChannel {
                            DevChannelBadge()
                        }
                    }
                } label: {
                    Text("授权对象")
                    Text(
                        "在「系统设置 › 隐私与安全性 › 屏幕录制」里勾选它；"
                            + "若列表里没有它，点列表左下的「+」手动选中这个 App。"
                    )
                }

                LabeledContent {
                    // 统一走拖拽授权：打开系统设置并浮出面板，把 App 卡片拖进列表即可。
                    Button("拖拽授权…") {
                        triedGranting = true
                        PermissionDragController.shared.present()
                        refresh()
                    }
                    .help("打开系统设置并浮出面板，把本 App 的卡片拖进列表")
                } label: {
                    Text("授权操作")
                }

                if suggestsRelaunch {
                    LabeledContent {
                        Button("重启 Jietu") { ScreenCapturePermission.relaunchApp() }
                    } label: {
                        Text("需要重启")
                        Text("macOS 的限制：授权只在授权之后启动的进程里生效。")
                    }
                }
            } header: {
                SettingsSectionHeader(title: "权限")
            } footer: {
                Text(
                    "授权状态每秒复查一次，从系统设置切回来会立刻更新。\n"
                        + "自签名 / Debug 构建有时不会自动出现在系统设置的列表里"
                        + "（但授权本身照样生效），用「拖拽授权…」把本 App 拖进去即可。"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in refresh() }
    }

    private func refresh() {
        let current = ScreenCapturePermission.isGranted
        if current != granted { granted = current }
    }
}
