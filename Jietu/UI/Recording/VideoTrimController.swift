import AVKit
import AppKit
import SwiftUI

/// 裁剪视频的窗口：上面播放器（系统那套控制条），下面电影胶片条（iMovie 风格的拖拽裁剪）。
///
/// 交互刻意做小：拖手柄选区间，「设为开头 / 设为结尾」按当前播放头取点，保存就直通导出。
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
            videoURL: url,
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

// MARK: - 裁剪界面本体

/// @author ixxxxoooo
struct VideoTrimView: View {
    let player: AVPlayer
    let videoURL: URL
    let loadDuration: () async -> TimeInterval
    let onSeek: (TimeInterval) -> Void
    let onExport: (TimeInterval, TimeInterval) -> Void
    let onCancel: () -> Void

    @State private var duration: TimeInterval = 0
    @State private var start: TimeInterval = 0
    @State private var end: TimeInterval = 0
    @State private var thumbnails: [CGImage] = []
    @State private var currentTime: TimeInterval = 0
    @State private var timeObserver: AnyObject?

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            TrimPlayerView(player: player)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.menuPanel))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                FilmstripTrimBar(
                    duration: duration,
                    start: $start,
                    end: $end,
                    currentTime: currentTime,
                    thumbnails: thumbnails,
                    onSeek: onSeek
                )
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
                Text("拖手柄选区间，或用播放头取点。裁剪点会对齐到最近的关键帧。")
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
        .task { await loadContent() }
        .onAppear { startTimeObserver() }
        .onDisappear { stopTimeObserver() }
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

    private func loadContent() async {
        let loaded = await loadDuration()
        duration = max(0, loaded)
        if end <= 0 { end = duration }
        // 加载电影胶片缩略图（~20 帧，后台异步取）。
        thumbnails = await VideoThumbnail.filmstrip(for: videoURL)
    }

    private func startTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30, preferredTimescale: 600)
        let observer = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak player] time in
            guard player != nil else { return }
            Task { @MainActor in currentTime = CMTimeGetSeconds(time) }
        }
        timeObserver = observer as AnyObject
    }

    private func stopTimeObserver() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    /// `m:ss.d`——裁剪要精确到 0.1 秒，纯 `m:ss` 看不出拖了多少。
    static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }
}

// MARK: - 播放器视图

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

// MARK: - 电影胶片条

/// iMovie 风格的电影胶片裁剪条：缩略图序列 + 黄色选区框 + 拖拽手柄。
///
/// 交互逻辑：
/// - 拖左手柄 → 调整起点，夹在 `[0, end - 最短长度]`；
/// - 拖右手柄 → 调整终点，夹在 `[start + 最短长度, 总时长]`；
/// - 点击胶片空白处 → 跳到那个时间点（快速定位）；
/// - 白色竖线 = 当前播放头位置。
///
/// @author ixxxxoooo
private struct FilmstripTrimBar: View {
    let duration: TimeInterval
    @Binding var start: TimeInterval
    @Binding var end: TimeInterval
    let currentTime: TimeInterval
    let thumbnails: [CGImage]
    var onSeek: ((TimeInterval) -> Void)?

    /// 胶片条高度（50pt，iPhone / iMovie 常用档——足够看清画面又不挤播放器）。
    private let barHeight: CGFloat = 50
    /// 手柄宽度（拖拽热区）。
    private let handleWidth: CGFloat = 12
    /// 选区边框宽度（顶部 / 底部黄线）。
    private let borderWidth: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            ZStack(alignment: .leading) {
                // 底层：缩略图铺满
                thumbnailStrip(width: width)

                // 选区之外的暗化遮罩
                dimOverlay(width: width)

                // 选区边框（黄色 U 形框：上 + 下 + 左手柄 + 右手柄）
                selectionFrame(width: width)

                // 播放头（白色竖线）
                playhead(width: width)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard duration > 0 else { return }
                let seconds = Double(location.x / width) * duration
                onSeek?(min(max(0, seconds), duration))
            }
        }
        .frame(height: barHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 缩略图条

    private func thumbnailStrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                // 占位：还没加载出来时显示深灰底
                Rectangle()
                    .fill(Theme.Colors.controlSurface)
                    .frame(width: width, height: barHeight)
            } else {
                ForEach(thumbnails.indices, id: \.self) { i in
                    Image(nsImage: NSImage(cgImage: thumbnails[i], size: .zero))
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(
                            width: width / CGFloat(thumbnails.count),
                            height: barHeight
                        )
                        .clipped()
                }
            }
        }
    }

    // MARK: - 暗化遮罩

    private func dimOverlay(width: CGFloat) -> some View {
        let sx = startFraction(width)
        let ex = endFraction(width)
        return ZStack(alignment: .leading) {
            // 左侧暗区
            Rectangle()
                .fill(.black.opacity(0.55))
                .frame(width: max(0, sx))
            // 右侧暗区
            Rectangle()
                .fill(.black.opacity(0.55))
                .frame(width: max(0, width - ex))
                .offset(x: ex)
        }
    }

    // MARK: - 选区边框（黄色 U 形框）

    private func selectionFrame(width: CGFloat) -> some View {
        let sx = startFraction(width)
        let ex = endFraction(width)
        let selWidth = max(0, ex - sx)
        return ZStack(alignment: .leading) {
            // 上边线
            Rectangle()
                .fill(Theme.Colors.accent)
                .frame(width: selWidth, height: borderWidth)
                .offset(x: sx)
            // 下边线
            Rectangle()
                .fill(Theme.Colors.accent)
                .frame(width: selWidth, height: borderWidth)
                .offset(x: sx, y: barHeight - borderWidth)

            // 左手柄
            trimHandle(isStart: true, width: width)
            // 右手柄
            trimHandle(isStart: false, width: width)
        }
    }

    /// 手柄：黄色竖条 + 中心小抓手指示符。
    private func trimHandle(isStart: Bool, width: CGFloat) -> some View {
        let x = isStart ? startFraction(width) - handleWidth : endFraction(width)
        return RoundedRectangle(cornerRadius: 3)
            .fill(Theme.Colors.accent)
            .frame(width: handleWidth, height: barHeight)
            .overlay {
                // 三条小横线（抓手）
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(.white.opacity(0.8))
                            .frame(width: 6, height: 1)
                    }
                }
            }
            .offset(x: x)
            .gesture(handleDrag(isStart: isStart, width: width))
    }

    // MARK: - 播放头

    private func playhead(width: CGFloat) -> some View {
        let fraction = duration > 0 ? CGFloat(currentTime / duration) : 0
        let x = min(max(0, fraction), 1) * width
        return Rectangle()
            .fill(.white)
            .frame(width: 2, height: barHeight)
            .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 0)
            .offset(x: x - 1)
            .allowsHitTesting(false)
    }

    // MARK: - 手势

    private func handleDrag(isStart: Bool, width: CGFloat) -> some Gesture {
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
            .onEnded { _ in
                // 松手后把播放头吸到手柄位置，方便预览裁剪点。
                onSeek?(isStart ? start : end)
            }
    }

    // MARK: - 坐标转换

    private func startFraction(_ width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(0, start / duration), 1)) * width
    }

    private func endFraction(_ width: CGFloat) -> CGFloat {
        guard duration > 0 else { return width }
        return CGFloat(min(max(0, end / duration), 1)) * width
    }
}
