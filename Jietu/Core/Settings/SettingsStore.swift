import Foundation
import Observation

@Observable
final class SettingsStore {
    private enum Key {
        static let hotkeyAreaCapture = "hotkey.areaCapture"
        static let copyToClipboard = "behavior.copyToClipboard"
        static let playShutterSound = "behavior.playShutterSound"
        static let saveToDisk = "behavior.saveToDisk"
        static let saveDirectoryPath = "behavior.saveDirectoryPath"
    }

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.copyToClipboard = defaults.object(forKey: Key.copyToClipboard) as? Bool ?? true
        self.playShutterSound = defaults.object(forKey: Key.playShutterSound) as? Bool ?? true
        self.saveToDisk = defaults.object(forKey: Key.saveToDisk) as? Bool ?? false

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
