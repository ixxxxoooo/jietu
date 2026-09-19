import AppKit

/// 设置窗口的标题栏：内联标题（当前分区名）+ 回退 / 前进两个导航按钮。
///
/// 用 AppKit 的 `NSToolbar` 而不是 SwiftUI 的 `.toolbar`——后者只对 SwiftUI `Scene`
/// 拥有的窗口生效，本 App 是菜单栏代理（LSUIElement）手管窗口，够不着。
///
/// 三件事一起做才能让标题「内联在分区列、靠左」而不是居中：
/// `titleVisibility = .visible` + `toolbarStyle = .unified` + 按钮 `isNavigational`。
/// 同时把 `titlebarAppearsTransparent` 设回 `false`——设置窗是唯一保留系统标题栏
/// 玻璃带的窗口，面板的 `Form` 滚到栏下时由 AppKit 画那条边缘效果。
///
/// @author ixxxxoooo
@MainActor
final class SettingsToolbarController: NSObject, WindowChrome, NSToolbarDelegate {
    private static let back = NSToolbarItem.Identifier("SettingsBack")
    private static let forward = NSToolbarItem.Identifier("SettingsForward")

    private let navigation: SettingsNavigationState
    private weak var window: NSWindow?
    private let backButton: NSButton
    private let forwardButton: NSButton

    init(navigation: SettingsNavigationState) {
        self.navigation = navigation
        // 两个独立按钮，不用 segmented：后者会在中间画一条分隔线。
        backButton = Self.makeButton("chevron.backward", L10n.settingsBack)
        forwardButton = Self.makeButton("chevron.forward", L10n.settingsForward)
        super.init()
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
    }

    // MARK: - WindowChrome

    func install(in window: NSWindow) {
        self.window = window
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        // `.automatic` 会在内容滚到栏下时画一条细线，把表面切两半。
        window.titlebarSeparatorStyle = .none
        // 设回 false：设置窗要系统标题栏那条玻璃带。
        window.titlebarAppearsTransparent = false
        // 系统设置的窗口不会被内容拖动——在 `Form` 上拖不该移动窗口。
        window.isMovableByWindowBackground = false

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        // 显示标签会在双箭头下面印「后退/前进」并把栏高一倍。
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // 两个都要关，否则右键仍会冒出显示模式菜单。
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar

        observe()
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // 追踪分隔符之后的东西都属于分区（详情）列。
        [.sidebarTrackingSeparator, Self.back, Self.forward]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.back:
            item.view = backButton
            item.label = L10n.settingsBack
        case Self.forward:
            item.view = forwardButton
            item.label = L10n.settingsForward
        default:
            return nil
        }
        // 唯一能把项目排在内联标题之前、而不是之后的标志。
        item.isNavigational = true
        item.visibilityPriority = .high
        // 按钮的可用性来自历史，而不是响应链校验。
        item.autovalidates = false
        return item
    }

    // MARK: - Private

    @objc private func goBack() { navigation.goBack() }
    @objc private func goForward() { navigation.goForward() }

    /// 每次读取后重新挂钩；`onChange` 在写入落盘前触发，所以跳一跳到主队列。
    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func sync() {
        window?.title = navigation.section.title
        backButton.isEnabled = navigation.canGoBack
        forwardButton.isEnabled = navigation.canGoForward
    }

    /// 用方向性的箭头（不是 `chevron.left/right`），这样 RTL 下会自动镜像。
    private static func makeButton(_ symbol: String, _ label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.bezelStyle = .toolbar
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }
}
