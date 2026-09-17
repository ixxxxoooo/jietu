import AppKit
import SwiftUI

/// 滚动长图的悬浮控制条：贴在选框下方（跟随选区），先让用户选「手动 / 自动」，
/// 开始后换成进度 + 完成 / 取消。
///
/// 关键点：抓取时把本 App 排除在画面外（`CaptureEngine.captureRegion`），
/// 所以这个控制条即使压在选区上也不会被拍进长图。
///
/// @author ixxxxoooo
final class ScrollingCapturePanelController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<ScrollingCapturePanelView>?
    /// 最后一次「贴着谁」的选区（AppKit 全局坐标）：切阶段重排尺寸时还要用它。
    private var anchorRect: CGRect?

    /// 框选期间停在「待开始」，由用户点按钮决定怎么滚。
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

    /// 两个阶段的尺寸：待开始是一条紧凑的「手动 / 自动」条，跑起来才换成进度卡。
    private static func size(for stage: Stage) -> NSSize {
        switch stage {
        case .ready: return Theme.Size.scrollingModeBar
        case .running: return Theme.Size.scrollingPanel
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 贴着选区下方展示（下方放不下就挪到上方）：初始为「待开始」。
    func present(near screenRect: CGRect) {
        close()
        stage = .ready
        height = 0
        anchorRect = screenRect

        let size = Self.size(for: stage)
        let root = makeRoot()
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        self.hosting = hosting

        let panel = NSPanel(
            contentRect: NSRect(origin: origin(for: screenRect, size: size), size: size),
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

    /// 选区被拖动 / 缩放：控制条一路贴着它走。
    func move(near screenRect: CGRect) {
        guard let panel else { return }
        anchorRect = screenRect
        panel.setFrameOrigin(origin(for: screenRect, size: panel.frame.size))
    }

    /// 切到「进行中」并更新已拼接高度（像素）。
    func setRunning(mode: ScrollingCaptureSession.Mode) {
        stage = .running(mode)
        height = 0
        resize()
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

    /// 进度卡比模式条高：换尺寸时保持「贴着选框」的锚点。
    private func resize() {
        guard let panel, let anchorRect else { return }
        let size = Self.size(for: stage)
        hosting?.frame = NSRect(origin: .zero, size: size)
        panel.setFrame(
            NSRect(origin: origin(for: anchorRect, size: size), size: size),
            display: true
        )
    }

    /// 贴着选区**下方**（下方实在放不下才翻到上方），两种情况都夹在屏幕可视区内。
    private func origin(for screenRect: CGRect, size: NSSize) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(screenRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 12
        let inset: CGFloat = 8

        var originY = screenRect.minY - size.height - gap
        if originY < visible.minY + inset {
            originY = screenRect.maxY + gap
        }
        originY = min(
            max(originY, visible.minY + inset),
            max(visible.minY + inset, visible.maxY - size.height - inset)
        )

        var originX = screenRect.midX - size.width / 2
        originX = min(
            max(originX, visible.minX + inset),
            max(visible.minX + inset, visible.maxX - size.width - inset)
        )
        return CGPoint(x: originX, y: originY)
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
        anchorRect = nil
    }
}

/// 控制条内容：待开始 = 一条紧凑的「手动 / 自动」模式条；跑起来 = 进度卡。
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
        switch stage {
        case .ready:
            modeBar
        case .running(let mode):
            progressCard(mode)
        }
    }

    /// 待开始：贴着选框下方的一条窄条，只回答「谁来滚」。
    private var modeBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "scroll")
                .font(Theme.Typography.bar)
                .foregroundStyle(Theme.Colors.textSecondary)
                .help("滚动长图：框好区域，选谁来滚")
            Spacer(minLength: Theme.Spacing.sm)
            GlassButton(title: "手动", systemImage: "hand.draw", action: onStartManual)
                .help("点完自己把鼠标放进选区往下滚")
            GlassButton(
                title: "自动", systemImage: "wand.and.rays", role: .prominent, action: onStartAuto
            )
            .help("由 Jietu 自己滚动（需要辅助功能权限）")
            GlassCircleButton(
                title: "取消（Esc）",
                systemImage: "xmark",
                diameter: Theme.Size.scrollingModeBarClose,
                tint: Theme.Colors.textSecondary,
                action: onCancel
            )
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(
            width: Theme.Size.scrollingModeBar.width,
            height: Theme.Size.scrollingModeBar.height,
            alignment: .center
        )
        .floatingSurface()
    }

    private func progressCard(_ mode: ScrollingCaptureSession.Mode) -> some View {
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
            Text(hintText(mode))
                .font(Theme.Typography.rowSubtitle)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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

    private var trailingText: String {
        height > 0 ? "已拼接 \(height) px" : "准备滚动…"
    }

    private func hintText(_ mode: ScrollingCaptureSession.Mode) -> String {
        switch mode {
        case .automatic:
            return "正在自动滚动…任意键停止，到底后自动完成。"
        case .manual:
            return "匀速滚动，停止约 1.5 秒自动完成。"
        }
    }
}
