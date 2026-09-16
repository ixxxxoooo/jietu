import AppKit
import SwiftUI

/// 设置页左侧的分类。
///
/// 每个分类带一个 `Theme.Colors.Accent` 主题色：侧边栏图标与内容区行图标共用它，
/// 这样左右两栏的配色是一致的。
///
/// @author ixxxxoooo
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case capture
    case hotkeys
    case quickAccess
    case annotation
    case permission

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .capture: return "截图"
        case .hotkeys: return "快捷键"
        case .quickAccess: return "预览浮窗"
        case .annotation: return "标注"
        case .permission: return "权限"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "camera.viewfinder"
        case .hotkeys: return "keyboard"
        case .quickAccess: return "rectangle.on.rectangle"
        case .annotation: return "pencil.tip.crop.circle"
        case .permission: return "lock.shield"
        }
    }

    /// 该分区的主题色（图标专用，文本仍走墨色 ramp）。
    var tint: Color {
        switch self {
        case .general: return Theme.Colors.Accent.blue
        case .capture: return Theme.Colors.Accent.green
        case .hotkeys: return Theme.Colors.Accent.amber
        case .quickAccess: return Theme.Colors.Accent.teal
        case .annotation: return Theme.Colors.Accent.violet
        case .permission: return Theme.Colors.Accent.rose
        }
    }
}

/// 偏好设置主界面：左侧分类，右侧分组表单。
///
/// 风格对齐 Tinycast 的设置页——侧栏 `List(.sidebar)`，详情用系统 `Form(.grouped)`
/// 分组卡片；图标用分区主题色，文本 / 间距 / 圆角全部走 `Theme`。
///
/// @author ixxxxoooo
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    /// 某个动作的热键改变时通知外部重新注册（nil 表示清除）。
    var onHotkeyChange: (HotkeyAction, Hotkey?) -> Void

    @State private var section: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label {
                    Text(item.title)
                } icon: {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.tint)
                }
                .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(
                min: 190,
                ideal: Theme.Size.settingsSidebar,
                max: 260
            )
        } detail: {
            detail
                .frame(
                    minWidth: Theme.Size.settingsDetailMinimum,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
                .background(
                    VisualEffectView(material: .contentBackground, blending: .behindWindow)
                        .ignoresSafeArea()
                )
        }
        .onChange(of: settings.launchAtLogin) { _, newValue in
            LaunchAtLogin.setEnabled(newValue)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .general: generalSection
        case .capture: captureSection
        case .hotkeys: hotkeysSection
        case .quickAccess: quickAccessSection
        case .annotation: annotationSection
        case .permission: permissionSection
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        let tint = SettingsSection.general.tint
        return Form {
            Section {
                SettingsToggleRow(
                    icon: "power",
                    tint: tint,
                    title: "登录时启动",
                    subtitle: "开机后自动启动 Jietu，随菜单栏常驻。",
                    isOn: $settings.launchAtLogin
                )
                SettingsToggleRow(
                    icon: "speaker.wave.2",
                    tint: tint,
                    title: "截图后播放快门音",
                    subtitle: "截图成功时播放系统快门声。",
                    isOn: $settings.playShutterSound
                )
                SettingsToggleRow(
                    icon: "doc.on.clipboard",
                    tint: tint,
                    title: "截图后自动复制到剪贴板",
                    subtitle: "截图后立即写入剪贴板，可直接粘贴。",
                    isOn: $settings.copyToClipboard
                )
                SettingsToggleRow(
                    icon: "bell",
                    tint: tint,
                    title: "保存后显示系统通知",
                    subtitle: "保存到磁盘后弹出通知，点击可定位文件。",
                    isOn: $settings.showSaveNotification
                )
            } header: {
                SettingsSectionHeader(title: "通用")
            } footer: {
                Text("这些是每次截图都会用到的默认行为。")
                    .font(Theme.Typography.rowSubtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 截图

    private var captureSection: some View {
        let tint = SettingsSection.capture.tint
        return Form {
            Section {
                SettingsToggleRow(
                    icon: "externaldrive",
                    tint: tint,
                    title: "自动保存到磁盘",
                    subtitle: "截图后自动写入下面选定的保存位置。",
                    isOn: $settings.saveToDisk
                )
                SettingsControlRow(
                    icon: "folder",
                    tint: tint,
                    title: "保存位置",
                    subtitle: settings.saveDirectory.path,
                    subtitleLineLimit: 1,
                    isActive: settings.saveToDisk
                ) {
                    Button("选择…") { chooseDirectory() }
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([settings.saveDirectory])
                    }
                }
            } header: {
                SettingsSectionHeader(title: "输出")
            }

            Section {
                SettingsControlRow(
                    icon: "photo",
                    tint: tint,
                    title: "保存格式",
                    subtitle: "PNG 无损体积大，JPEG 可调质量。"
                ) {
                    Picker(selection: $settings.saveFormat) {
                        ForEach(SaveFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                SettingsControlRow(
                    icon: "slider.horizontal.3",
                    tint: tint,
                    title: "JPEG 质量",
                    subtitle: "只在 JPEG 格式下生效。",
                    isActive: settings.saveFormat == .jpeg
                ) {
                    Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                        .frame(width: 180)
                    Text(String(format: "%.0f%%", settings.jpegQuality * 100))
                        .font(Theme.Typography.numeric)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(width: 42, alignment: .trailing)
                }
            } header: {
                SettingsSectionHeader(title: "格式")
            }

            Section {
                SettingsControlRow(
                    icon: "textformat.abc",
                    tint: tint,
                    title: "文件名模板",
                    subtitle: "\(FilenameTemplate.placeholderHint)\n示例：\(previewFilename)",
                    subtitleLineLimit: 3,
                    isActive: settings.saveToDisk
                ) {
                    TextField(FilenameTemplate.defaultTemplate, text: $settings.filenameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Button("恢复默认") {
                        settings.filenameTemplate = FilenameTemplate.defaultTemplate
                    }
                }
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

    // MARK: - 快捷键

    private var hotkeysSection: some View {
        let tint = SettingsSection.hotkeys.tint
        return Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HotkeyRecorderView(
                        title: action.title,
                        subtitle: action.subtitle,
                        icon: action.symbol,
                        tint: tint,
                        hotkey: Binding(
                            get: { settings.hotkey(for: action) },
                            set: { newValue in
                                settings.setHotkey(newValue, for: action)
                                onHotkeyChange(action, newValue)
                            }
                        )
                    )
                }
            } header: {
                SettingsSectionHeader(title: "快捷键")
            } footer: {
                Text(
                    "默认都不设置快捷键，点了「未设置」再按组合键即可录入；「清除」可删掉。\n"
                        + "全局热键会抢占其它 App 的同名组合键，建议避开常用组合。"
                )
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 预览浮窗

    private var quickAccessSection: some View {
        let tint = SettingsSection.quickAccess.tint
        return Form {
            Section {
                SettingsControlRow(
                    icon: "rectangle.on.rectangle",
                    tint: tint,
                    title: "停靠位置",
                    subtitle: "截图后浮窗出现在屏幕的哪个角。"
                ) {
                    Picker(selection: $settings.quickAccessPosition) {
                        ForEach(QuickAccessPosition.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SettingsControlRow(
                    icon: "timer",
                    tint: tint,
                    title: "自动关闭",
                    subtitle: "浮窗多久后自动消失，「永不」则需手动关闭。"
                ) {
                    Picker(selection: $settings.quickAccessAutoCloseDelay) {
                        Text("1 秒").tag(TimeInterval(1))
                        Text("3 秒").tag(TimeInterval(3))
                        Text("5 秒").tag(TimeInterval(5))
                        Text("10 秒").tag(TimeInterval(10))
                        Text("30 秒").tag(TimeInterval(30))
                        Text("60 秒").tag(TimeInterval(60))
                        Text("永不").tag(TimeInterval(0))
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                }
            } header: {
                SettingsSectionHeader(title: "预览浮窗")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 标注

    private var annotationSection: some View {
        let tint = SettingsSection.annotation.tint
        return Form {
            Section {
                SettingsControlRow(
                    icon: "pencil.tip.crop.circle",
                    tint: tint,
                    title: "编辑方式",
                    subtitle: "就地编辑：截完直接在当前画面上标注。\n独立窗口：截完先显示浮窗，点开后在单独窗口编辑。"
                ) {
                    Picker(selection: $settings.editorMode) {
                        ForEach(EditorMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                }
            } header: {
                SettingsSectionHeader(title: "标注")
            }

            Section {
                SettingsControlRow(
                    icon: "paintpalette",
                    tint: tint,
                    title: "默认样式",
                    subtitle: styleSummary
                ) {
                    Button("恢复默认") { settings.annotationDefaults = .standard }
                }
            } header: {
                SettingsSectionHeader(title: "默认样式")
            } footer: {
                Text("工具 / 颜色 / 参数沿用上次用法。")
                    .font(Theme.Typography.rowSubtitle)
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

    // MARK: - 权限

    private var permissionSection: some View {
        let tint = SettingsSection.permission.tint
        let granted = ScreenCapturePermission.isGranted
        return Form {
            Section {
                SettingsRow(
                    title: granted ? "屏幕录制：已授权" : "屏幕录制：未授权",
                    subtitle: granted
                        ? "Jietu 可以正常冻结屏幕并截图。"
                        : "没有它，截图会返回空白画面。",
                    icon: {
                        SettingsIcon(
                            systemImage: granted
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                            tint: granted ? Theme.Colors.success : Theme.Colors.warning
                        )
                    }
                ) {
                    EmptyView()
                }

                SettingsControlRow(
                    icon: "lock.shield",
                    tint: tint,
                    title: "授权操作"
                ) {
                    Button("打开系统设置") { ScreenCapturePermission.openSystemSettings() }
                    Button("授权屏幕录制") {
                        if !ScreenCapturePermission.request() {
                            ScreenCapturePermission.openSystemSettings()
                        }
                    }
                }
            } header: {
                SettingsSectionHeader(title: "权限")
            } footer: {
                Text("授权后需重启 Jietu 才会生效（macOS 限制）。")
                    .font(Theme.Typography.rowSubtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 便捷方法

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
