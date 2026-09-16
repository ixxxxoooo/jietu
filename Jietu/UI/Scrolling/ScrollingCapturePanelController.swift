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

    private static let size = NSSize(width: 300, height: 84)

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 贴着选区下方展示（下方放不下就挪到上方）。
    func present(near screenRect: CGRect) {
        close()

        let root = ScrollingCapturePanelView(
            height: 0,
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
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// 更新已拼接高度（像素）。
    func update(height: Int) {
        guard let hosting else { return }
        hosting.rootView = ScrollingCapturePanelView(
            height: height,
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
    var onFinish: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scroll")
                Text("滚动长图")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text(height > 0 ? "已拼接 \(height) px" : "等待滚动…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("请匀速滚动要截取的内容，停止滚动约 1.5 秒后自动完成。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("完成") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 300, height: 84, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
    }
}
