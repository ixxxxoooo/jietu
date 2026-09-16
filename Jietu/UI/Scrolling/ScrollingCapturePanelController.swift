import AppKit
import SwiftUI

/// 滚动长图的悬浮控制条：显示已拼接高度 + 完成 / 取消。
///
/// 关键点：抓取时把本 App 排除在画面外（`CaptureEngine.captureRegion`），
/// 所以这个控制条即使压在选区上也不会被拍进长图。
///
/// @author ixxxxoooo
final class ScrollingCapturePanelController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<ScrollingCapturePanelView>?

    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private var mode: ScrollingCaptureSession.Mode = .manual

    private static var size: NSSize { Theme.Size.scrollingPanel }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 贴着选区下方展示（下方放不下就挪到上方）。
    func present(near screenRect: CGRect, mode: ScrollingCaptureSession.Mode) {
        close()
        self.mode = mode

        let root = ScrollingCapturePanelView(
            height: 0,
            mode: mode,
            onFinish: { [weak self] in self?.onFinish?() },
            onCancel: { [weak self] in self?.onCancel?() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        self.hosting = hosting

        let screen = NSScreen.screens.first { $0.frame.intersects(screenRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let below = screenRect.minY - Self.size.height - 12
        let originY = below >= visible.minY ? below : screenRect.maxY + 12
        var originX = screenRect.midX - Self.size.width / 2
        originX = min(max(originX, visible.minX + 8), visible.maxX - Self.size.width - 8)

        let panel = NSPanel(
            contentRect: NSRect(origin: CGPoint(x: originX, y: originY), size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// 更新已拼接高度（像素）。
    func update(height: Int) {
        guard let hosting else { return }
        hosting.rootView = ScrollingCapturePanelView(
            height: height,
            mode: mode,
            onFinish: { [weak self] in self?.onFinish?() },
            onCancel: { [weak self] in self?.onCancel?() }
        )
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }
}

/// 控制条内容。
///
/// @author ixxxxoooo
struct ScrollingCapturePanelView: View {
    var height: Int
    var mode: ScrollingCaptureSession.Mode = .manual
    var onFinish: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "scroll")
                    .font(Theme.Typography.bar)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text("滚动长图")
                    .font(Theme.Typography.bar)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer(minLength: Theme.Spacing.md)
                Text(height > 0 ? "已拼接 \(height) px" : (mode == .automatic ? "准备滚动…" : "等待滚动…"))
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Text(
                mode == .automatic
                    ? "正在自动滚动…任意键停止，也会在到底后自动完成。"
                    : "匀速滚动，停止约 1.5 秒自动完成。"
            )
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
            HStack(spacing: Theme.Spacing.md) {
                Spacer(minLength: 0)
                GlassButton(title: "取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                GlassButton(title: "完成", role: .prominent, action: onFinish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(
            width: Theme.Size.scrollingPanel.width,
            height: Theme.Size.scrollingPanel.height,
            alignment: .topLeading
        )
        .floatingSurface()
    }
}
