import Observation

/// 设置窗口一次会话的导航状态：当前分区 + 回退 / 前进历史。
///
/// 只属于这一个窗口——窗口关掉就释放，历史不会跨会话残留。
///
/// @author ixxxxoooo
@MainActor
@Observable
final class SettingsNavigationState {
    private(set) var section: SettingsSection
    private var back: [SettingsSection] = []
    private var forward: [SettingsSection] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    init(section: SettingsSection = .general) {
        self.section = section
    }

    /// 侧栏点选：记进历史，并清空前进栈。
    func select(_ next: SettingsSection) {
        guard next != section else { return }
        back.append(section)
        forward.removeAll()
        section = next
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(section)
        section = previous
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(section)
        section = next
    }
}
