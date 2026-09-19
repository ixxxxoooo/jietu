import AppKit
import SwiftUI

/// Quick Access 浮窗的**队列**管理器。
///
/// 每张卡片是一个独立浮窗，从屏幕下缘的同一侧堆叠：
/// **最新的一张在最上面，早的依次在下面**。每张各自计时，到点后向屏幕边缘侧滑并淡出，
/// 其余浮窗自动补位。全部尺寸一致，只显示预览本身。
///
/// 卡片有两种，表面与交互同一套、动作各一套：
/// - **图片卡**（`QuickAccessView`）：截图，四角 + 中央「保存」；
/// - **视频卡**（`QuickAccessVideoView`）：录屏收工的 mp4，四角播放 / 在访达中显示 / 复制文件 / 关闭。
///
/// @author ixxxxoooo
final class QuickAccessPanelController {
    private final class Entry {
        let id: UUID
        let panel: NSPanel
        /// 这张卡片的尺寸（按预览的宽高比算出来的，叠放时按它占位）。
        let size: CGSize
        let displayID: CGDirectDisplayID
        let dragURL: URL?
        /// 关掉卡片时要不要顺手删掉 `dragURL`：图片卡那个是临时文件，视频卡的是用户的成片。
        let removesDragFile: Bool
        var deadline: Date?
        var isHovering = false

        init(
            id: UUID,
            panel: NSPanel,
            size: CGSize,
            displayID: CGDirectDisplayID,
            dragURL: URL?,
            removesDragFile: Bool
        ) {
            self.id = id
            self.panel = panel
            self.size = size
            self.displayID = displayID
            self.dragURL = dragURL
            self.removesDragFile = removesDragFile
        }
    }

    private var entries: [Entry] = []
    private var timer: Timer?

    private let inset: CGFloat = Theme.quickAccessInset
    private let gap: CGFloat = 10
    private let appearDuration: TimeInterval = 0.26
    private let slideOutDuration: TimeInterval = 0.24

    /// Quick Access 自动关闭延时（秒）。0 表示不自动关闭，由偏好设置驱动。
    var autoCloseDelay: TimeInterval = 3
    /// 停靠位置（屏幕左下 / 右下角），由偏好设置驱动。
    var position: QuickAccessPosition = .bottomRight

    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?
    /// 卡片上点了「编辑」：把这张图交给原地编辑器，并带上**卡片 id**——
    /// 编辑确认后那张旧卡片要让位，不然屏幕上会留着一张没编辑过的图，看着像「裁了没生效」。
    var onAnnotate: ((CGImage, UUID) -> Void)?
    var onPin: ((CGImage) -> Void)?
    /// 视频卡：播放（用默认播放器打开成片）。
    var onPlayVideo: ((URL) -> Void)?
    /// 视频卡：在访达中显示。
    var onRevealVideo: ((URL) -> Void)?
    /// 视频卡：把文件本身放进剪贴板（粘到聊天窗口 / 访达里就是那个 mp4）。
    var onCopyVideoFile: ((URL) -> Void)?
    /// 视频卡：保存（把成片另存一份到用户挑的地方）。
    var onSaveVideo: ((URL) -> Void)?
    /// 视频卡：裁剪（开裁剪窗口，另存一段）。
    var onTrimVideo: ((URL) -> Void)?
    /// 视频卡：导出 GIF。
    var onExportGif: ((URL) -> Void)?
    var onDismiss: (() -> Void)?
    /// 浮窗出现 / 全部消失。
    var onVisibilityChanged: ((Bool) -> Void)?

    var isVisible: Bool { !entries.isEmpty }

    /// 自检用：当前浮窗面板（取 frame 算注入点）。
    var panelsForTesting: [NSPanel] { entries.map(\.panel) }

    /// 自检用：当前卡片的 id（按叠放顺序）。
    var entryIDsForTesting: [UUID] { entries.map(\.id) }

    // MARK: - Present

    /// 截图的浮窗（图片卡）。
    func present(image: CGImage, onDisplay displayID: CGDirectDisplayID, saveDirectory: URL) {
        let id = UUID()
        // 卡片尺寸按截图的**自然点尺寸**（像素 ÷ 屏幕缩放）算，与它在屏幕上占多大一致：
        // 尺寸不同的截图走同一套交互，只是框大小不同；小图不会被放大。
        let screen = NSScreen.screens.first { $0.jietu_displayID == displayID } ?? NSScreen.main
        let backingScale = max(1, screen?.backingScaleFactor ?? 2)
        let pointSize = CGSize(
            width: CGFloat(image.width) / backingScale,
            height: CGFloat(image.height) / backingScale
        )
        let panelSize = QuickAccessView.panelSize(for: pointSize)
        let nsImage = NSImage(cgImage: image, size: NSSize(width: pointSize.width, height: pointSize.height))
        let dragURL = Self.writeDragFile(image)

        let root = QuickAccessView(
            image: nsImage,
            imagePointSize: pointSize,
            cardSize: panelSize,
            onCopy: { [weak self] in
                self?.onCopy?(image)
            },
            onSave: { [weak self] in
                self?.onSave?(image)
            },
            onAnnotate: { [weak self] in
                self?.onAnnotate?(image, id)
            },
            onPin: { [weak self] in
                self?.onPin?(image)
            },
            onClose: { [weak self] in self?.dismissEntry(id, animated: true) },
            onHoverChange: { [weak self] hovering in self?.setHover(id, hovering) },
            dragProvider: { [weak self] in
                if let url = self?.entries.first(where: { $0.id == id })?.dragURL,
                    let provider = NSItemProvider(contentsOf: url)
                {
                    return provider
                }
                return NSItemProvider(object: nsImage)
            }
        )

        insert(
            id: id,
            root: root,
            panelSize: panelSize,
            displayID: displayID,
            dragURL: dragURL,
            removesDragFile: true
        )
    }

    /// 录屏收工的浮窗（视频卡）。
    ///
    /// 与图片卡同一套尺寸规则（`QuickAccessView.panelSize`）：封面等比缩放、小图不放大，
    /// 叠放时按同一套槽位排队。拖出去的就是磁盘上那个 mp4（不是临时文件，关卡片不删）。
    func presentVideo(
        url: URL,
        thumbnail: CGImage,
        thumbnailPointSize: CGSize,
        duration: TimeInterval,
        onDisplay displayID: CGDirectDisplayID
    ) {
        let id = UUID()
        // 视频卡上下两排各三个圆盘，宽度下限比图片卡大一档。
        let panelSize = QuickAccessView.panelSize(
            for: thumbnailPointSize, minimum: Theme.Size.quickAccessVideoCardMin
        )
        let nsImage = NSImage(
            cgImage: thumbnail,
            size: NSSize(width: thumbnailPointSize.width, height: thumbnailPointSize.height)
        )

        let root = QuickAccessVideoView(
            thumbnail: nsImage,
            thumbnailPointSize: thumbnailPointSize,
            duration: duration,
            cardSize: panelSize,
            onPlay: { [weak self] in self?.onPlayVideo?(url) },
            onReveal: { [weak self] in self?.onRevealVideo?(url) },
            onCopyFile: { [weak self] in self?.onCopyVideoFile?(url) },
            onSave: { [weak self] in self?.onSaveVideo?(url) },
            onTrim: { [weak self] in self?.onTrimVideo?(url) },
            onExportGif: { [weak self] in self?.onExportGif?(url) },
            onClose: { [weak self] in self?.dismissEntry(id, animated: true) },
            onHoverChange: { [weak self] hovering in self?.setHover(id, hovering) },
            dragProvider: {
                NSItemProvider(contentsOf: url) ?? NSItemProvider(object: nsImage)
            }
        )

        insert(
            id: id,
            root: root,
            panelSize: panelSize,
            displayID: displayID,
            dragURL: url,
            removesDragFile: false
        )
    }

    /// 两种卡片共用的落地流程：建面板 → 摆到队列里 → 起计时。
    private func insert(
        id: UUID,
        root: some View,
        panelSize: CGSize,
        displayID: CGDirectDisplayID,
        dragURL: URL?,
        removesDragFile: Bool
    ) {
        let screen = NSScreen.screens.first { $0.jietu_displayID == displayID } ?? NSScreen.main
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: panelSize)

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
        // 阴影交给系统：内容是圆角卡片 + 透明窗口，AppKit 会按内容 alpha 画出贴合的阴影。
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting

        let target = frameFor(index: entries.count, size: panelSize, screen: screen)
        panel.setFrame(offscreenFrame(from: target, screen: screen), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        let entry = Entry(
            id: id,
            panel: panel,
            size: panelSize,
            displayID: displayID,
            dragURL: dragURL,
            removesDragFile: removesDragFile
        )
        entry.deadline = nextDeadline()
        let wasEmpty = entries.isEmpty
        entries.append(entry)
        if wasEmpty { onVisibilityChanged?(true) }

        if let screen, maxVisible(on: screen) < entries.count {
            dismissEntry(entries[0].id, animated: false)
        }

        layout(animated: true)
        startTimer()
    }

    /// 关闭全部浮窗（例如退出）。
    func dismiss() {
        let hadEntries = !entries.isEmpty
        timer?.invalidate()
        timer = nil
        for entry in entries {
            entry.panel.orderOut(nil)
            removeDragFile(entry)
        }
        entries.removeAll()
        if hadEntries { onDismiss?() }
    }

    /// 收掉某一张卡片（原地编辑确认后，被编辑的那张旧卡片让位用）。
    func dismiss(card id: UUID, animated: Bool = true) {
        dismissEntry(id, animated: animated)
    }

    // MARK: - Layout

    private func currentScreen() -> NSScreen? {
        guard let last = entries.last,
            let screen = NSScreen.screens.first(where: { $0.jietu_displayID == last.displayID })
        else { return NSScreen.main }
        return screen
    }

    private func maxVisible(on screen: NSScreen) -> Int {
        // 用最大卡片高度当槽位：尺寸各异的截图不会溢出屏幕。
        let slot = Theme.Size.quickAccessCardMax.height + gap
        let available = screen.visibleFrame.height - inset * 2 + gap
        return max(1, Int(available / slot))
    }

    private func frameFor(index: Int, size: CGSize, screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x: CGFloat
        switch position {
        case .bottomRight:
            x = visible.maxX - size.width - inset
        case .bottomLeft:
            x = visible.minX + inset
        }
        // 从下往上叠：每张按**自己的高度**占位，尺寸不同也不会互相压住。
        var y = visible.minY + inset
        for entry in entries.prefix(index) {
            y += entry.size.height + gap
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func offscreenFrame(from frame: NSRect, screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var offscreen = frame
        switch position {
        case .bottomRight:
            offscreen.origin.x = visible.maxX + 8
        case .bottomLeft:
            offscreen.origin.x = visible.minX - frame.width - 8
        }
        return offscreen
    }

    private func exitFrame(from frame: NSRect, screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var exit = frame
        switch position {
        case .bottomRight:
            exit.origin.x = visible.maxX + frame.width
        case .bottomLeft:
            exit.origin.x = visible.minX - frame.width * 2
        }
        return exit
    }

    private func layout(animated: Bool) {
        let screen = currentScreen()
        for (index, entry) in entries.enumerated() {
            let frame = frameFor(index: index, size: entry.size, screen: screen)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = appearDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    entry.panel.animator().setFrame(frame, display: true)
                    entry.panel.animator().alphaValue = 1
                } completionHandler: {
                    // AppKit 按「首次绘制时的 frame」缓存并缩放阴影，进场结束后要重算一次。
                    MainActor.assumeIsolated { entry.panel.invalidateShadow() }
                }
            } else {
                entry.panel.setFrame(frame, display: true)
                entry.panel.alphaValue = 1
                entry.panel.invalidateShadow()
            }
        }
    }

    // MARK: - Dismiss

    private func dismissEntry(_ id: UUID, animated: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        removeDragFile(entry)

        if animated, let screen = currentScreen() {
            let target = exitFrame(from: entry.panel.frame, screen: screen)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = slideOutDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                entry.panel.animator().setFrame(target, display: true)
                entry.panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                entry.panel.orderOut(nil)
                self?.layout(animated: true)
                self?.finishIfEmpty()
            }
        } else {
            entry.panel.orderOut(nil)
            layout(animated: true)
            finishIfEmpty()
        }
    }

    private func finishIfEmpty() {
        guard entries.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        onVisibilityChanged?(false)
        onDismiss?()
    }

    // MARK: - Hover

    private func setHover(_ id: UUID, _ hovering: Bool) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entry.isHovering = hovering
        entry.deadline = hovering ? nil : nextDeadline()
    }

    private func nextDeadline() -> Date? {
        guard autoCloseDelay > 0 else { return nil }
        return Date().addingTimeInterval(autoCloseDelay)
    }

    // MARK: - Auto close

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func tick() {
        guard autoCloseDelay > 0 else { return }
        let now = Date()
        // 一次只关一张，避免多张同时侧滑导致动画打架。
        guard
            let expired = entries.first(where: {
                !$0.isHovering && ($0.deadline.map { now >= $0 } ?? false)
            })
        else { return }

        dismissEntry(expired.id, animated: true)
    }

    // MARK: - Temp files

    private static func writeDragFile(_ image: CGImage) -> URL? {
        guard let data = CaptureOutput.pngData(image) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Jietu-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// 清掉**我们自己造的**临时导出文件。视频卡的 `dragURL` 是用户的成片，绝不能删。
    private func removeDragFile(_ entry: Entry) {
        guard entry.removesDragFile, let url = entry.dragURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
