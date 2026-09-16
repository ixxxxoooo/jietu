import AppKit
import SwiftUI

/// 权限引导窗口。
///
/// 与参考项目的 `AppWindowController` 一致：标题栏透明、内容通到栏下、窗口可被内容拖动，
/// 高度由向导每一步量出来的理想高度决定（`fit(height:)`），所以每一步都不裁不撑。
///
/// @author ixxxxoooo
final class OnboardingWindowController {
    private var window: NSWindow?
    private let model: OnboardingModel
    private var previousActivationPolicy: NSApplication.ActivationPolicy = .accessory

    init(settings: SettingsStore = SettingsStore()) {
        model = OnboardingModel(settings: settings)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate()
            return
        }

        // 权限引导需要正常出现在 Dock 和 ⌘-Tab 里，否则用户切不回来。
        previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)

        let root = OnboardingView(model: model) { [weak self] in
            self?.close()
        } onHeightChange: { [weak self] height in
            self?.fit(height: height)
        }
        let hosting = NSHostingController(rootView: root)
        // 窗口的尺寸说了算，不让 SwiftUI 的 fitting size 反过来撑它。
        hosting.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingView.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "欢迎使用 Jietu"
        // 内容通到栏下，读起来是一整块表面。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // 否则 AppKit 会在启动时凭空恢复窗口（那时什么都还没接好）。
        window.isRestorable = false
        window.contentViewController = hosting
        window.setContentSize(OnboardingView.initialSize)
        self.window = window

        window.center()
        // 激活可能失败（例如进程由终端派生），此时普通窗口会排在其它 App 之后。
        // orderFrontRegardless 保证引导窗一定可见。
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    /// 窗口取当前这一步量到的高度，保持上边缘不动往下长。
    func fit(height: CGFloat) {
        guard let window else { return }
        // 标题栏在 frame 里、不在布局区里，得加回去。
        let titlebar = window.frame.height - window.contentLayoutRect.height
        let size = CGSize(width: OnboardingView.width, height: height + titlebar)
        guard window.contentMinSize != size else { return }
        let top = window.frame.maxY
        window.contentMinSize = size
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        // 回到菜单栏代理模式。
        NSApp.setActivationPolicy(previousActivationPolicy)
    }
}
