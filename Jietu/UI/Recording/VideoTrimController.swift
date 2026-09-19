import AVKit
import AppKit
import SwiftUI

/// 裁剪视频的窗口：上面播放器（系统那套控制条），下面一条双柄时间轴。
///
/// 交互刻意做小：拖两个柄选区间，「设为开头 / 设为结尾」按当前播放头取点，保存就直通导出。
/// 不做逐帧预览、不做多段拼接——录屏裁剪要的是「掐头去尾」，一屏搞定。
///
/// @author ixxxxoooo
@MainActor
final class VideoTrimController: NSObject, NSWindowDelegate {
    private let url: URL
    private let player: AVPlayer
    private var window: NSWindow?

    /// 导出成功后回调（外面发通知 / 显示）。
    var onExported: ((URL) -> Void)?
    /// 窗口关掉后回调（外面清掉引用）。
    var onClose: (() -> Void)?

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)
        super.init()
    }

    func present(on screen: NSScreen?) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let root = VideoTrimView(
            player: player,
            loadDuration: { [url] in
                let asset = AVURLAsset(url: url)
                return CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
            },
            onSeek: { [weak self] seconds in
                self?.player.seek(
                    to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero
                )
            },
            onExport: { [weak self] start, end in self?.export(start: start, end: end) },
            onCancel: { [weak self] in self?.close() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "裁剪视频"
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 560, height: 420)
        if let screen {
            window.setFrameOrigin(
                NSPoint(
                    x: screen.visibleFrame.midX - window.frame.width / 2,
                    y: screen.visibleFrame.midY - window.frame.height / 2
                )
            )
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        window = nil
        onClose?()
    }

    // MARK: - 导出

    private func export(start: TimeInterval, end: TimeInterval) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue =
            "\(url.deletingPathExtension().lastPathComponent) 裁剪.mp4"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    try await VideoTrimmer.export(
                        from: self.url, to: destination, start: start, end: end
                    )
                    self.onExported?(destination)
                    self.close()
                } catch {
                    self.presentFailure(error)
                }
            }
        }
    }

    private func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "没能导出这段视频"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// 裁剪界面本体。
///
/// @author ixxxxoooo
struct VideoTrimView: View {
    let player: AVPlayer
    let loadDuration: () async -> TimeInterval
    let onSeek: (TimeInterval) -> Void
    let onExport: (TimeInterval, TimeInterval) -> Void
    let onCancel: () -> Void

    @State private var duration: TimeInterval = 0
    @State private var start: TimeInterval = 0
    @State private var end: TimeInterval = 0

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            TrimPlayerView(player: player)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.menuPanel))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                TrimRangeSlider(duration: duration, start: $start, end: $end)
                HStack(spacing: Theme.Spacing.md) {
                    Text(rangeText)
                        .font(Theme.Typography.numeric)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Spacer()
                    Button("设为开头") { setStartFromPlayhead() }
                    Button("设为结尾") { setEndFromPlayhead() }
                }
            }

            HStack(spacing: Theme.Spacing.md) {
                Text("拖两个圆点选一段，或用播放头取点。裁剪点会对齐到最近的关键帧。")
                    .font(Theme.Typography.rowSubtitle)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存裁剪") { onExport(start, end) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(duration <= 0 || end - start < TrimRange.minimumLength)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(minWidth: 560, minHeight: 420)
        .task {
            let loaded = await loadDuration()
            duration = max(0, loaded)
            if end <= 0 { end = duration }
        }
    }

    private var rangeText: String {
        "\(Self.timeText(start)) – \(Self.timeText(end))（共 \(Self.timeText(max(0, end - start)))）"
    }

    private func setStartFromPlayhead() {
        let now = CMTimeGetSeconds(player.currentTime())
        start = min(max(0, now), max(0, end - TrimRange.minimumLength))
        onSeek(start)
    }

    private func setEndFromPlayhead() {
        let now = CMTimeGetSeconds(player.currentTime())
        end = max(min(max(0, duration), now), start + TrimRange.minimumLength)
        onSeek(end)
    }

    /// `m:ss.d`——裁剪要精确到 0.1 秒，纯 `m:ss` 看不出拖了多少。
    static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }
}

/// 带系统控制条的播放器视图。
///
/// **刻意不用 SwiftUI 自带的 `VideoPlayer`**：它继承自 AVKit 的 `AVPlayerView`，而
/// SwiftUI 只会把 `_AVKit_SwiftUI` 链进来、不链 `AVKit` 本体，运行时解析父类直接终止进程
/// （实测：`failed to demangle superclass of VideoPlayerView from mangled name
/// 'So12AVPlayerViewC'`，且没有任何崩溃报告）。直接包 AppKit 的 `AVPlayerView` 既绕开
/// 那条继承链，也真的用到了 AVKit 的符号。
///
/// @author ixxxxoooo
private struct TrimPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // 常驻控制条：裁剪时要盯着播放头取点，不该等悬停才出来。
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// 双柄时间轴：一条轨道 + 两个圆点，拖出要保留的区间。
///
/// @author ixxxxoooo
private struct TrimRangeSlider: View {
    let duration: TimeInterval
    @Binding var start: TimeInterval
    @Binding var end: TimeInterval

    private let handleSize: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let startX = fraction(start) * width
            let endX = fraction(end) * width
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Theme.Colors.controlSurface)
                    .frame(width: width, height: 4)
                    .offset(y: (handleSize - 4) / 2)
                Capsule()
                    .fill(Theme.Colors.accent)
                    .frame(width: max(0, endX - startX), height: 4)
                    .offset(x: startX, y: (handleSize - 4) / 2)
                handle.offset(x: startX - handleSize / 2)
                    .gesture(drag(width: width, isStart: true))
                handle.offset(x: endX - handleSize / 2)
                    .gesture(drag(width: width, isStart: false))
            }
        }
        .frame(height: handleSize)
    }

    private var handle: some View {
        Circle()
            .fill(.white)
            .frame(width: handleSize, height: handleSize)
            .overlay(Circle().stroke(Theme.Colors.accent, lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }

    private func fraction(_ seconds: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(0, seconds / duration), 1))
    }

    private func drag(width: CGFloat, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0 else { return }
                let seconds = Double(min(max(0, value.location.x / width), 1)) * duration
                if isStart {
                    start = min(seconds, max(0, end - TrimRange.minimumLength))
                } else {
                    end = max(seconds, min(duration, start + TrimRange.minimumLength))
                }
            }
    }
}
