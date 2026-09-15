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

@Observable
final class SettingsStore {
    private enum Key {
        static let hotkeyAreaCapture = "hotkey.areaCapture"
        static let copyToClipboard = "behavior.copyToClipboard"
        static let playShutterSound = "behavior.playShutterSound"
        static let saveToDisk = "behavior.saveToDisk"
        static let saveDirectoryPath = "behavior.saveDirectoryPath"
        static let quickAccessAutoCloseDelay = "behavior.quickAccessAutoCloseDelay"
        static let recentCapturePaths = "history.recentCapturePaths"
        static let launchAtLogin = "behavior.launchAtLogin"
        static let saveFormat = "behavior.saveFormat"
        static let jpegQuality = "behavior.jpegQuality"
        static let quickAccessPosition = "behavior.quickAccessPosition"
    }

    /// 最近截图最多保留的条数。
    static let maxRecentCaptures = 8

    private let defaults: UserDefaults

    var hotkeyAreaCapture: Hotkey {
        didSet { persistHotkey() }
    }

    var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Key.copyToClipboard) }
    }

    var playShutterSound: Bool {
        didSet { defaults.set(playShutterSound, forKey: Key.playShutterSound) }
    }

    var saveToDisk: Bool {
        didSet { defaults.set(saveToDisk, forKey: Key.saveToDisk) }
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
    var saveFormat: SaveFormat {
        didSet { defaults.set(saveFormat.rawValue, forKey: Key.saveFormat) }
    }

    /// JPEG 压缩质量（0...1）。仅 `saveFormat == .jpeg` 时生效。
    var jpegQuality: Double {
        didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) }
    }

    /// Quick Access 预览卡的停靠位置。
    var quickAccessPosition: QuickAccessPosition {
        didSet { defaults.set(quickAccessPosition.rawValue, forKey: Key.quickAccessPosition) }
    }

    /// 最近保存的截图路径（新的在前）。
    private(set) var recentCapturePaths: [String] {
        didSet { defaults.set(recentCapturePaths, forKey: Key.recentCapturePaths) }
    }

    /// 最近截图的文件 URL。
    var recentCaptureURLs: [URL] {
        recentCapturePaths.map { URL(fileURLWithPath: $0) }
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

        self.copyToClipboard = defaults.object(forKey: Key.copyToClipboard) as? Bool ?? true
        self.playShutterSound = defaults.object(forKey: Key.playShutterSound) as? Bool ?? true
        self.saveToDisk = defaults.object(forKey: Key.saveToDisk) as? Bool ?? false
        self.quickAccessAutoCloseDelay =
            defaults.object(forKey: Key.quickAccessAutoCloseDelay) as? Double ?? 3
        self.launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        self.recentCapturePaths = defaults.stringArray(forKey: Key.recentCapturePaths) ?? []
        self.saveFormat =
            (defaults.string(forKey: Key.saveFormat).flatMap(SaveFormat.init(rawValue:))) ?? .png
        self.jpegQuality = defaults.object(forKey: Key.jpegQuality) as? Double ?? 0.9
        self.quickAccessPosition =
            (defaults.string(forKey: Key.quickAccessPosition)
                .flatMap(QuickAccessPosition.init(rawValue:))) ?? .bottomRight

        if let path = defaults.string(forKey: Key.saveDirectoryPath) {
            self.saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            self.saveDirectory = (pictures ?? FileManager.default.homeDirectoryForCurrentUser)
                .appendingPathComponent("Jietu", isDirectory: true)
        }

        if
            let data = defaults.data(forKey: Key.hotkeyAreaCapture),
            let stored = try? JSONDecoder().decode(Hotkey.self, from: data)
        {
            self.hotkeyAreaCapture = stored
        } else {
            self.hotkeyAreaCapture = .captureArea
        }
    }

    private func persistHotkey() {
        guard let data = try? JSONEncoder().encode(hotkeyAreaCapture) else { return }
        defaults.set(data, forKey: Key.hotkeyAreaCapture)
    }
}
