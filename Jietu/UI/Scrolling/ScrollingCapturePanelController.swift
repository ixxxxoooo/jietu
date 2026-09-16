import AppKit
import SwiftUI

/// 滚动长图的悬浮控制条：先让用户选「自动截图 / 开始截图」，开始后显示进度 + 完成 / 取消。
///
/// 关键点：抓取时把本 App 排除在画面外（`CaptureEngine.captureRegion`），
/// 所以这个控制条即使压在选区上也不会被拍进长图。
///
/// @author ixxxxoooo
final class ScrollingCapturePanelController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<ScrollingCapturePanelView>?

    /// 框选完成后先停在「待开始」，由用户点按钮决定怎么滚。
    enum Stage: Equatable {
        case ready
        case running(ScrollingCaptureSession.Mode)
    }

    private var stage: Stage = .ready
    private var height = 0

    var onStartManual: (() -> Void)?
    var onStartAuto: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private static var size: NSSize { Theme.Size.scrollingPanel }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 贴着选区下方展示（下方放不下就挪到上方）：初始为「待开始」。
    func present(near screenRect: CGRect) {
        close()
        stage = .ready
        height = 0

        let root = makeRoot()
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
        // 高于遮罩（滚动长图期间遮罩留着当取景框，压在它下面就看不见了）。
        panel.level = .screenSaver + 1
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

    /// 切到「进行中」并更新已拼接高度（像素）。
    func setRunning(mode: ScrollingCaptureSession.Mode) {
        stage = .running(mode)
        height = 0
        refresh()
    }

    /// 更新已拼接高度（像素）。
    func update(height: Int) {
        self.height = height
        refresh()
    }

    private func refresh() {
        hosting?.rootView = makeRoot()
    }

    private func makeRoot() -> ScrollingCapturePanelView {
        ScrollingCapturePanelView(
            height: height,
            stage: stage,
            onStartManual: { [weak self] in self?.onStartManual?() },
            onStartAuto: { [weak self] in self?.onStartAuto?() },
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
    var stage: ScrollingCapturePanelController.Stage = .ready
    var onStartManual: () -> Void = {}
    var onStartAuto: () -> Void = {}
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
                Text(trailingText)
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            Text(hintText)
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Spacing.md) {
                Spacer(minLength: 0)
                GlassButton(title: "取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if case .ready = stage {
                    GlassButton(title: "开始截图", action: onStartManual)
                        .help("点完自己把鼠标放进选区往下滚")
                    GlassButton(title: "自动截图", role: .prominent, action: onStartAuto)
                        .help("由 Jietu 自己滚动（需要辅助功能权限）")
                } else {
                    GlassButton(title: "完成", role: .prominent, action: onFinish)
                        .keyboardShortcut(.defaultAction)
                }
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

    private var trailingText: String {
        switch stage {
        case .ready: return "框选完成"
        case .running:
            return height > 0 ? "已拼接 \(height) px" : "准备滚动…"
        }
    }

    private var hintText: String {
        switch stage {
        case .ready:
            return "自动截图：它自己滚；开始截图：你把鼠标放进选区自己滚。"
        case .running(.automatic):
            return "正在自动滚动…任意键停止，到底后自动完成。"
        case .running(.manual):
            return "匀速滚动，停止约 1.5 秒自动完成。"
        }
    }
}
