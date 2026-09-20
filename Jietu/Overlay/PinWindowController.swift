import AppKit
import QuartzCore
import VisionKit

/// 「钉图」：把截图钉在屏幕上，作为一个可拖动、可缩放的浮动窗口。
///
/// 支持：
/// - 拖动任意位置移动
/// - 拖动边缘 / 角改变大小（保持宽高比）
/// - 滚轮 / 触控板捏合缩放
/// - 右键菜单：识别文本、翻译、复制图像、关闭
/// - 双击关闭；Esc 关闭；⌘W 快速关闭
/// - 右上角磨砂玻璃关闭按钮（悬停显示；进入识别文本后常驻）
/// - 左上角编辑按钮：点一下回到标注编辑器（钉图关掉，编辑器用同一张图打开）
/// - 左下角翻译按钮：识别图上的文字，交给 **macOS 自己的翻译面板**（Translation.framework）
/// - 右下角识别文本按钮：点开即选中态，按钮转成 macOS 那颗蓝底实心样式；再点一次退出
///
/// @author ixxxxoooo
final class PinWindowController: NSObject {
    private static var controllers: [PinWindowController] = []

    /// 点了钉图上的「编辑」：把图与钉图的位置交给外面（`AppDelegate` 据此开标注编辑器）。
    ///
    /// 钉图本身不碰编辑器——它连 AppDelegate 都不该知道；这条闭包由 AppDelegate 在启动时接上。
    static var onRequestEdit: ((CGImage, CGRect) -> Void)?

    /// 新钉的图要不要加边框光晕（设置页「外观 › 钉图」）。
    ///
    /// 同样由 AppDelegate 接上设置存储；只影响之后新钉的图，已经在屏上的不回改。
    static var isBorderGlowEnabled: () -> Bool = { false }

    private let window: PinPanel
    private let content: PinContentView
    private var monitor: Any?
    /// 开了光晕才有的那一层发光窗口。
    private var glow: PinGlowController?

    /// 钉一张截图。多张可共存。
    ///
    /// - Parameter targetFrame: 指定屏幕坐标位置与大小（用于「原地钉图」）；
    ///   为 nil 时按原始大小钉在**屏幕正中**。
    static func pin(image: CGImage, on screen: NSScreen?, targetFrame: CGRect? = nil) {
        let controller = PinWindowController(image: image, screen: screen, targetFrame: targetFrame)
        controllers.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(image: CGImage, screen: NSScreen?, targetFrame: CGRect?) {
        let target = screen ?? NSScreen.main
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let frame: NSRect
        if let targetFrame, targetFrame.width > 1, targetFrame.height > 1 {
            // 原地钉图：直接使用编辑器里图片所在的位置与大小。
            frame = targetFrame
        } else {
            // 默认按**原始大小**显示：像素尺寸除以屏幕缩放。超过屏幕 90% 才等比缩小。
            let backingScale = target?.backingScaleFactor ?? 2
            let naturalSize = CGSize(
                width: CGFloat(image.width) / backingScale,
                height: CGFloat(image.height) / backingScale
            )
            let maxSize = CGSize(width: visible.width * 0.9, height: visible.height * 0.9)
            let scale = min(
                1,
                min(maxSize.width / naturalSize.width, maxSize.height / naturalSize.height)
            )
            let size = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
            // 钉在屏幕正中；每多钉一张向右下错开一点，避免完全重叠。
            let offset = CGFloat(PinWindowController.controllers.count % 6) * 24
            let origin = CGPoint(
                x: visible.midX - size.width / 2 + offset,
                y: visible.midY - size.height / 2 - offset
            )
            frame = NSRect(origin: origin, size: size)
        }

        content = PinContentView(frame: NSRect(origin: .zero, size: frame.size), image: image)
        window = PinPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.contentView = content
        window.initialFirstResponder = content
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        // 禁用系统自动拖动，由 PinContentView 自行区分边缘调整与内容拖拽。
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true

        content.onRequestClose = { [weak self] in self?.close() }
        content.onRequestEdit = { [weak self] in self?.requestEdit() }

        if PinWindowController.isBorderGlowEnabled() {
            // 系统阴影收掉：光晕自己就是一圈发光，两者叠着只会发灰。
            window.hasShadow = false
            let glow = PinGlowController(pinWindow: window)
            window.onFrameChanged = { [weak glow] frame in
                glow?.syncFrame(forPinFrame: frame)
            }
            self.glow = glow
        }

        // Esc / ⌘W 快捷关闭当前 key 钉图浮窗
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
                self.close()
                return nil
            }
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "e" {
                self.requestEdit()
                return nil
            }
            return event
        }
    }

    /// 「编辑」：先把钉图收掉，再把图交给外面开编辑器（回到编辑器的感觉，不留一张重复的钉图）。
    private func requestEdit() {
        let frame = window.frame
        close()
        PinWindowController.onRequestEdit?(content.cgImage, frame)
    }

    private func close() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        glow?.detach()
        glow = nil
        window.orderOut(nil)
        PinWindowController.controllers.removeAll { $0 === self }
        // 若还有剩余钉图，激活上一张为 key window
        PinWindowController.controllers.last?.window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 测试钩子

    /// 测试用：当前每张钉图上的光晕窗口 frame（没开光晕的钉图不在里面）。
    static var pinnedGlowFramesForTesting: [CGRect] {
        controllers.compactMap { $0.glow?.frameForTesting }
    }

    /// 测试用：把还钉着的图全收掉（用例之间别互相留窗口）。
    static func closeAllForTesting() {
        for controller in controllers {
            controller.close()
        }
    }

}

/// 无边框但可成为 key 的钉图面板。
///
/// @author ixxxxoooo
