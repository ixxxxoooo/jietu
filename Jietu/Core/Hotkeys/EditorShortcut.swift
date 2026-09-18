import AppKit
import Carbon.HIToolbox
import Foundation

/// 标注编辑器**内部**的快捷键。
///
/// 与 `HotkeyAction` 不是一回事：那些是 Carbon 全局热键（`RegisterEventHotKey`），
/// 注册之后在任何 App 里都生效；这里两条只在标注编辑器拿到键盘焦点时生效，
/// 走各编辑器自己的键盘事件。**刻意不注册全局热键**——把 ⌘Z 抢成全局，
/// 系统里所有别的 App 的撤销都会一起废掉。
///
/// @author ixxxxoooo
enum EditorShortcut: String, CaseIterable, Identifiable, Codable {
    /// 回退上一步。
    case undo
    /// 重做被撤销的一步。
    case redo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .undo: return "撤销"
        case .redo: return "重做"
        }
    }

    /// 设置页里的说明文案。
    var subtitle: String {
        switch self {
        case .undo: return "标注编辑时回退上一步"
        case .redo: return "重做被撤销的一步"
        }
    }

    /// 设置页 / 工具栏图标的 SF Symbol。
    var symbol: String {
        switch self {
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        }
    }

    /// 出厂默认绑定：macOS 惯例的那一对，**不是空的**——设置页里默认就配好。
    ///
    /// 选 ⇧⌘Z 而不是 Windows 味的 ⌘Y 当重做：macOS 上 ⇧⌘Z 才是系统惯例，
    /// 独立窗口编辑器本来也就是这么绑的，两处保持一致。想换 ⌘Y 在设置页改一下即可。
    var defaultHotkey: Hotkey {
        switch self {
        case .undo:
            return Hotkey(
                keyCode: UInt32(kVK_ANSI_Z),
                carbonModifiers: UInt32(cmdKey),
                menuKeyEquivalent: "z"
            )
        case .redo:
            return Hotkey(
                keyCode: UInt32(kVK_ANSI_Z),
                carbonModifiers: UInt32(cmdKey | shiftKey),
                menuKeyEquivalent: "z"
            )
        }
    }
}

/// 标注编辑器实际使用的两条快捷键。
///
/// 存「整份」而不是「覆盖表」：`nil` 表示用户**显式解绑**，与「没存过、用出厂默认」
/// 是两种状态——只有首次启动（读不到数据）才落到 `.standard`。
///
/// @author ixxxxoooo
struct EditorShortcuts: Codable, Equatable {
    var undo: Hotkey?
    var redo: Hotkey?

    /// 出厂状态：⌘Z 撤销、⇧⌘Z 重做。
    static let standard = EditorShortcuts(
        undo: EditorShortcut.undo.defaultHotkey,
        redo: EditorShortcut.redo.defaultHotkey
    )

    /// 取某一条当前的绑定；`nil` 表示这条被解绑了。
    func hotkey(for shortcut: EditorShortcut) -> Hotkey? {
        switch shortcut {
        case .undo: return undo
        case .redo: return redo
        }
    }

    /// 改写某一条（传 `nil` 解绑）。
    mutating func set(_ hotkey: Hotkey?, for shortcut: EditorShortcut) {
        switch shortcut {
        case .undo: undo = hotkey
        case .redo: redo = hotkey
        }
    }
}
