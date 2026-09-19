import Foundation
import Observation

/// 截图落盘格式。
///
/// @author ixxxxoooo
enum SaveFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

/// Quick Access 预览卡出现的位置（屏幕左下 / 右下角）。
///
/// @author ixxxxoooo
enum QuickAccessPosition: String, CaseIterable, Identifiable {
    case bottomRight
    case bottomLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottomRight: return "右下角"
        case .bottomLeft: return "左下角"
        }
    }
}

/// 截选后流程设置。
///
/// @author ixxxxoooo
enum EditorMode: String, CaseIterable, Identifiable {
    /// 立即标注：截完直接在当前截图上编辑，工具栏原地出现，`✓/✗` 决定。
    case inline
    /// 浮窗预览：截完先显示浮窗卡片，点开后居中原地编辑。
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inline: return "立即标注"
        case .window: return "浮窗预览"
        }
    }
}

@Observable
final class SettingsStore {
    private enum Key {
        static let recordSystemAudio = "recording.systemAudio"
        static let recordFrameRate = "recording.frameRate"
        /// 多热键映射（动作 rawValue → 组合键）。
        static let hotkeys = "hotkeys.map"
        /// 旧版本只存区域截图一个热键，启动时迁移到 `hotkeys`。
        static let legacyHotkeyAreaCapture = "hotkey.areaCapture"
        /// 标注编辑器内部的两条快捷键（撤销 / 重做）。
        static let editorShortcuts = "editor.shortcuts"
        static let appearance = "appearance.theme"
        static let copyToClipboard = "behavior.copyToClipboard"
        static let playShutterSound = "behavior.playShutterSound"
        static let saveToDisk = "behavior.saveToDisk"
        static let showSaveNotification = "behavior.showSaveNotification"
        static let saveDirectoryPath = "behavior.saveDirectoryPath"
        static let quickAccessAutoCloseDelay = "behavior.quickAccessAutoCloseDelay"
        static let recentCapturePaths = "history.recentCapturePaths"
        static let launchAtLogin = "behavior.launchAtLogin"
        static let saveFormat = "behavior.saveFormat"
        static let filenameTemplate = "behavior.filenameTemplate"
        static let jpegQuality = "behavior.jpegQuality"
        static let quickAccessPosition = "behavior.quickAccessPosition"
        static let editorMode = "behavior.editorMode"
        static let annotationDefaults = "annotation.defaults"
        static let windowShadowEnabled = "behavior.windowShadowEnabled"
        static let windowShadowSize = "behavior.windowShadowSize"
    }

    /// 最近截图最多保留的条数。
    static let maxRecentCaptures = 10

    private let defaults: UserDefaults

    /// 各动作的全局热键。**没设置的动作不在表里**（默认全部不设）。
    var hotkeys: [HotkeyAction: Hotkey] {
        didSet { persistHotkeys() }
    }

    /// 读取某个动作的热键；nil 表示用户还没设置。
    func hotkey(for action: HotkeyAction) -> Hotkey? {
        hotkeys[action]
    }

    /// 设置（或传 nil 清除）某个动作的热键。
    func setHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) {
        if let hotkey {
            hotkeys[action] = hotkey
        } else {
            hotkeys.removeValue(forKey: action)
        }
    }

    /// 区域截图热键（多热键之前的旧入口，保留给已有调用方）。
    var hotkeyAreaCapture: Hotkey? {
        get { hotkey(for: .areaCapture) }
        set { setHotkey(newValue, for: .areaCapture) }
    }

    /// 标注编辑器内部的两条快捷键（撤销 / 重做）。
    ///
    /// 与 `hotkeys` 的「默认全部为空」相反：这里**出厂就配好**（⌘Z / ⇧⌘Z），
    /// 用户可以在设置页改，也可以解绑（解绑后不再自动填回默认）。
    var editorShortcuts: EditorShortcuts {
        didSet { persistEditorShortcuts() }
    }

    /// 恢复出厂的那一对（⌘Z / ⇧⌘Z）。
    func resetEditorShortcuts() {
        editorShortcuts = .standard
    }

    var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Key.copyToClipboard) }
    }

    /// 外观：跟随系统 / 锁定浅色 / 锁定深色。
    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var playShutterSound: Bool {
        didSet { defaults.set(playShutterSound, forKey: Key.playShutterSound) }
    }

    var saveToDisk: Bool {
        didSet { defaults.set(saveToDisk, forKey: Key.saveToDisk) }
    }

    /// 保存成功后是否发系统通知（点击可在访达中定位文件）。
    var showSaveNotification: Bool {
        didSet { defaults.set(showSaveNotification, forKey: Key.showSaveNotification) }
    }

    var saveDirectory: URL {
        didSet { defaults.set(saveDirectory.path, forKey: Key.saveDirectoryPath) }
    }

    /// Quick Access 预览的自动关闭延时（秒）。0 表示不自动关闭。
    var quickAccessAutoCloseDelay: TimeInterval {
        didSet { defaults.set(quickAccessAutoCloseDelay, forKey: Key.quickAccessAutoCloseDelay) }
    }

    /// 是否开机自启（登录时启动）。
    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    /// 落盘格式。
    /// 录屏时是否连系统声音一起录（页面里的视频 / 音乐）。默认关：不录声音更省事也更少翻车。
    var recordSystemAudio: Bool {
        didSet { defaults.set(recordSystemAudio, forKey: Key.recordSystemAudio) }
    }

    /// 录屏帧率（30 / 60）。60 更顺，文件也更大。
    var recordFrameRate: Int {
        didSet { defaults.set(recordFrameRate, forKey: Key.recordFrameRate) }
    }

    var saveFormat: SaveFormat {
        didSet { defaults.set(saveFormat.rawValue, forKey: Key.saveFormat) }
    }

    /// 落盘文件名模板，支持 `{date}` / `{time}` / `{datetime}` / `{counter}`。
    ///
    /// 这里存用户原样输入；空模板与非法字符由 `FilenameTemplate` 在展开时兜底。
    var filenameTemplate: String {
        didSet { defaults.set(filenameTemplate, forKey: Key.filenameTemplate) }
    }

    /// 展开后的模板（空值回落到默认模板）。
    var effectiveFilenameTemplate: String {
        FilenameTemplate.resolvedTemplate(filenameTemplate)
    }

    /// JPEG 压缩质量（0...1）。仅 `saveFormat == .jpeg` 时生效。
    var jpegQuality: Double {
        didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) }
    }

    /// Quick Access 预览卡的停靠位置。
    var quickAccessPosition: QuickAccessPosition {
        didSet { defaults.set(quickAccessPosition.rawValue, forKey: Key.quickAccessPosition) }
    }

    /// 标注编辑方式（原地 / 独立窗口）。
    var editorMode: EditorMode {
        didSet { defaults.set(editorMode.rawValue, forKey: Key.editorMode) }
    }

    /// 窗口截图是否自动裁出圆角并加上 macOS 风格拟物阴影。
    var windowShadowEnabled: Bool {
        didSet { defaults.set(windowShadowEnabled, forKey: Key.windowShadowEnabled) }
    }

    /// 窗口截图阴影大小（pt）。
    var windowShadowSize: Double {
        didSet { defaults.set(windowShadowSize, forKey: Key.windowShadowSize) }
    }

    /// 标注的默认样式：工具 / 颜色 / 线宽 / 字号 / 马赛克块 / 模糊半径 / 放大倍率 / 橡皮大小。
    var annotationDefaults: AnnotationDefaults {
        didSet { persistAnnotationDefaults() }
    }

    /// 最近保存的截图路径（新的在前）。
    private(set) var recentCapturePaths: [String] {
        didSet { defaults.set(recentCapturePaths, forKey: Key.recentCapturePaths) }
    }

    /// 最近截图的文件 URL（新的在前）。
    ///
    /// 已被删除 / 移走的文件不再返回：这几条是历史记录，文件没了就既预览不了也打不开。
    var recentCaptureURLs: [URL] {
        recentCapturePaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 记录一次保存，超出上限的旧记录会被丢弃。
    func recordCapture(_ url: URL) {
        var paths = recentCapturePaths.filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        if paths.count > Self.maxRecentCaptures {
            paths = Array(paths.prefix(Self.maxRecentCaptures))
        }
        recentCapturePaths = paths
    }

    func clearRecentCaptures() {
        recentCapturePaths = []
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.appearance =
            defaults.string(forKey: Key.appearance).flatMap(AppAppearance.init) ?? .system
        self.copyToClipboard = defaults.object(forKey: Key.copyToClipboard) as? Bool ?? true
        self.playShutterSound = defaults.object(forKey: Key.playShutterSound) as? Bool ?? true
        self.saveToDisk = defaults.object(forKey: Key.saveToDisk) as? Bool ?? false
        self.showSaveNotification =
            defaults.object(forKey: Key.showSaveNotification) as? Bool ?? true
        self.quickAccessAutoCloseDelay =
            defaults.object(forKey: Key.quickAccessAutoCloseDelay) as? Double ?? 30
        self.launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        self.recordSystemAudio =
            defaults.object(forKey: Key.recordSystemAudio) as? Bool ?? false
        self.recordFrameRate = defaults.object(forKey: Key.recordFrameRate) as? Int ?? 30
        self.recentCapturePaths = defaults.stringArray(forKey: Key.recentCapturePaths) ?? []
        self.saveFormat =
            (defaults.string(forKey: Key.saveFormat).flatMap(SaveFormat.init(rawValue:))) ?? .png
        self.filenameTemplate =
            defaults.string(forKey: Key.filenameTemplate) ?? FilenameTemplate.defaultTemplate
        self.jpegQuality = defaults.object(forKey: Key.jpegQuality) as? Double ?? 0.9
        self.quickAccessPosition =
            (defaults.string(forKey: Key.quickAccessPosition)
                .flatMap(QuickAccessPosition.init(rawValue:))) ?? .bottomLeft
        self.editorMode =
            (defaults.string(forKey: Key.editorMode).flatMap(EditorMode.init(rawValue:))) ?? .inline
        self.windowShadowEnabled = defaults.object(forKey: Key.windowShadowEnabled) as? Bool ?? true
        self.windowShadowSize = defaults.object(forKey: Key.windowShadowSize) as? Double ?? 32.0
        if let data = defaults.data(forKey: Key.annotationDefaults),
            let stored = try? JSONDecoder().decode(AnnotationDefaults.self, from: data)
        {
            self.annotationDefaults = stored.sanitized
        } else {
            self.annotationDefaults = .standard
        }

        if let path = defaults.string(forKey: Key.saveDirectoryPath) {
            self.saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            self.saveDirectory = (pictures ?? FileManager.default.homeDirectoryForCurrentUser)
                .appendingPathComponent("Jietu", isDirectory: true)
        }

        if
            let data = defaults.data(forKey: Key.hotkeys),
            let stored = try? JSONDecoder().decode([String: Hotkey].self, from: data)
        {
            self.hotkeys = Dictionary(
                uniqueKeysWithValues: stored.compactMap { raw, hotkey in
                    HotkeyAction(rawValue: raw).map { ($0, hotkey) }
                }
            )
        } else if
            let data = defaults.data(forKey: Key.legacyHotkeyAreaCapture),
            let stored = try? JSONDecoder().decode(Hotkey.self, from: data)
        {
            // 迁移：旧版本只有一个区域截图热键。
            self.hotkeys = [.areaCapture: stored]
        } else {
            self.hotkeys = [:]
        }

        if
            let data = defaults.data(forKey: Key.editorShortcuts),
            let stored = try? JSONDecoder().decode(EditorShortcuts.self, from: data)
        {
            self.editorShortcuts = stored
        } else {
            // 首次启动（或数据坏了）落到出厂默认：默认就配好 ⌘Z / ⇧⌘Z，而不是留空。
            self.editorShortcuts = .standard
        }
    }

    private func persistEditorShortcuts() {
        guard let data = try? JSONEncoder().encode(editorShortcuts) else { return }
        defaults.set(data, forKey: Key.editorShortcuts)
    }

    private func persistHotkeys() {
        let raw = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: Key.hotkeys)
    }

    private func persistAnnotationDefaults() {
        guard let data = try? JSONEncoder().encode(annotationDefaults) else { return }
        defaults.set(data, forKey: Key.annotationDefaults)
    }
}
