import AppKit
import SwiftUI

/// 截图后的浮动预览窗。
///
/// 用非激活面板：不抢前台 App 的焦点，用户可以直接接着敲键盘。
final class QuickAccessPanelController {
    private let inset: CGFloat = Theme.quickAccessInset
    private let autoCloseInterval: TimeInterval = 3

    private var panel: NSPanel?
    private var panelSize: CGSize = .zero
    private var timer: Timer?
    private var deadline: Date?
    private var isHovering = false

    private var image: CGImage?
    private var saveDirectory: URL?

    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?
    var onDismiss: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(image: CGImage, onDisplay displayID: CGDirectDisplayID, saveDirectory: URL) {
        dismiss()

        self.image = image
        self.saveDirectory = saveDirectory

        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        let byteSize = CaptureOutput.pngData(image)?.count ?? 0

        let root = QuickAccessView(
            image: nsImage,
            pixelSize: CGSize(width: image.width, height: image.height),
            byteSize: byteSize,
            onCopy: { [weak self] in
                guard let self, let image = self.image else { return }
                self.onCopy?(image)
            },
            onSave: { [weak self] in
                guard let self, let image = self.image else { return }
                self.onSave?(image)
            },
            onClose: { [weak self] in self?.dismiss() },
            onHoverChange: { [weak self] hovering in
                self?.handleHover(hovering)
            }
        )

        let hosting = NSHostingView(rootView: root)
        // 用内容的自适应尺寸定面板大小，避免手写数字导致底部留白 / 裁切。
        let fitting = hosting.fittingSize
        panelSize = CGSize(
            width: max(fitting.width, QuickAccessView.cardWidth),
            height: max(fitting.height, QuickAccessView.cardHeight)
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 边框窗口的自阴影是直角矩形，和圆角卡片对不上，改用 SwiftUI 的阴影。
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        // 截图 HUD 恒为深色：否则浅色系统外观下白色文字会看不见。
        panel.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel

        let target = targetFrame(onDisplay: displayID)
        // 从右下角滑入：先落在目标位置下方 12pt，再动画到位。
        panel.setFrame(target.offsetBy(dx: 0, dy: -12), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.quickAccessSlideIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }

        startAutoClose()
    }

    func dismiss() {
        let hadPanel = panel != nil
        timer?.invalidate()
        timer = nil
        deadline = nil
        isHovering = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        image = nil
        // present() 开头会先 dismiss 旧的，此时不应该回调。
        if hadPanel { onDismiss?() }
    }

    // MARK: - Layout

    private func targetFrame(onDisplay displayID: CGDirectDisplayID) -> NSRect {
        let screen = NSScreen.screens.first { $0.jietu_displayID == displayID } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visible.maxX - panelSize.width - inset,
            y: visible.minY + inset,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    // MARK: - Auto close

    private func handleHover(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            deadline = nil
        } else {
            startAutoClose()
        }
    }

    private func startAutoClose() {
        deadline = Date().addingTimeInterval(autoCloseInterval)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let deadline = self.deadline else { return }
                if Date() >= deadline {
                    self.dismiss()
                }
            }
        }
    }
}
