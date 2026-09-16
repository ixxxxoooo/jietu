import AppKit
import SwiftUI

/// 设置页左侧的分类。
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
}

/// 偏好设置主界面：左侧分类，右侧内容。
///
/// @author ixxxxoooo
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    /// 某个动作的热键改变时通知外部重新注册。
    var onHotkeyChange: (HotkeyAction, Hotkey) -> Void

    @State private var section: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 168, ideal: 176, max: 210)
        } detail: {
            ScrollView {
                detail
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 660, height: 470)
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

    // MARK: - Sections

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("通用")
            Toggle("登录时启动", isOn: $settings.launchAtLogin)
            Toggle("截图后播放快门音", isOn: $settings.playShutterSound)
            Toggle("截图后自动复制到剪贴板", isOn: $settings.copyToClipboard)
            Toggle("保存后显示系统通知", isOn: $settings.showSaveNotification)
            Divider()
            Text("这些是每次截图都会用到的默认行为。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("截图")
            Toggle("自动保存到磁盘", isOn: $settings.saveToDisk)
            directoryRow
            Divider()
            Picker("保存格式", selection: $settings.saveFormat) {
                ForEach(SaveFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 12) {
                Text("JPEG 质量")
                Slider(value: $settings.jpegQuality, in: 0.3...1.0)
                    .frame(maxWidth: 220)
                Text(String(format: "%.0f%%", settings.jpegQuality * 100))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .disabled(settings.saveFormat != .jpeg)
            .opacity(settings.saveFormat == .jpeg ? 1 : 0.45)
            Divider()
            filenameTemplateRow
        }
    }

    private var filenameTemplateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("文件名模板")
                TextField(FilenameTemplate.defaultTemplate, text: $settings.filenameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .disabled(!settings.saveToDisk)
                Button("恢复默认") {
                    settings.filenameTemplate = FilenameTemplate.defaultTemplate
                }
                .disabled(!settings.saveToDisk)
            }
            Text("\(FilenameTemplate.placeholderHint)\n示例：\(previewFilename)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
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

    private var directoryRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("保存位置")
                    .font(.system(size: 13))
                Text(settings.saveDirectory.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("选择…") { chooseDirectory() }
                .disabled(!settings.saveToDisk)
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([settings.saveDirectory])
            }
            .disabled(!settings.saveToDisk)
        }
    }

    private var hotkeysSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("快捷键")
            ForEach(HotkeyAction.allCases) { action in
                HotkeyRecorderView(
                    title: action.title,
                    subtitle: action.subtitle,
                    hotkey: Binding(
                        get: { settings.hotkey(for: action) },
                        set: { newValue in
                            settings.setHotkey(newValue, for: action)
                            onHotkeyChange(action, newValue)
                        }
                    )
                )
            }
            Divider()
            Text("全局热键，点击右侧按钮后按下新的组合键；至少需要一个修饰键，Esc 取消。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("预览浮窗")
            Picker("停靠位置", selection: $settings.quickAccessPosition) {
                ForEach(QuickAccessPosition.allCases) { position in
                    Text(position.title).tag(position)
                }
            }
            .pickerStyle(.segmented)
            Picker("自动关闭", selection: $settings.quickAccessAutoCloseDelay) {
                Text("1 秒").tag(TimeInterval(1))
                Text("3 秒").tag(TimeInterval(3))
                Text("5 秒").tag(TimeInterval(5))
                Text("10 秒").tag(TimeInterval(10))
                Text("30 秒").tag(TimeInterval(30))
                Text("60 秒").tag(TimeInterval(60))
                Text("永不").tag(TimeInterval(0))
            }
        }
    }

    private var annotationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("标注")
            Picker("编辑方式", selection: $settings.editorMode) {
                ForEach(EditorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            Text("就地编辑：截完直接在当前画面上标注，工具栏就地出现。\n独立窗口：截完先显示浮窗，点开后在单独窗口编辑。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Divider()
            defaultStyleRow
        }
    }

    /// 当前记住的默认样式（工具 / 颜色 / 参数沿用上次用法）。
    private var defaultStyleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("默认样式")
                    .font(.system(size: 13))
                Text(styleSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("恢复默认") { settings.annotationDefaults = .standard }
        }
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

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("权限")
            HStack(spacing: 8) {
                Image(
                    systemName: ScreenCapturePermission.isGranted
                        ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(ScreenCapturePermission.isGranted ? .green : .orange)
                Text(
                    ScreenCapturePermission.isGranted
                        ? "屏幕录制权限：已授权" : "屏幕录制权限：未授权"
                )
            }
            HStack {
                Button("打开系统设置") { ScreenCapturePermission.openSystemSettings() }
                Button("授权屏幕录制") {
                    if !ScreenCapturePermission.request() {
                        ScreenCapturePermission.openSystemSettings()
                    }
                }
            }
            Text("授权后需重启 Jietu 才会生效（macOS 限制）。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
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
