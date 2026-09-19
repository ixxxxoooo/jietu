import AppKit
import os

/// AppDelegate — 截图结果交付（处理遮罩返回、保存、历史、浮窗）。
///
/// @author ixxxxoooo
extension AppDelegate {
    func handleOverlayOutcome(_ outcome: OverlayCoordinator.Outcome) {
        switch outcome {
        case .cancelled:
            // 遮罩被取消（Esc / 右键）：滚动长图还停在「选模式」这一步时，
            // 挂在选框下面的那条模式条也得一起收掉。
            if scrollingSession == nil { dismissScrollingPanel() }
            // 取消编辑：那张浮窗卡片**留着**（用户没改东西，截图不该凭空消失）。
            cardBeingEdited = nil
        case .captured(let image, let displayID, let screenRect, let annotated):
            if annotated {
                // 已在遮罩里原地标注完成，直接走交付流程。
                deliver(image, onDisplay: displayID)
            } else {
                handleCaptured(image, onDisplay: displayID, screenRect: screenRect)
            }
        case .windowCaptured(let window, let snapshot):
            handleWindowCaptured(window: window, snapshot: snapshot)
        }
    }

    /// 窗口截图完成：优先独立截取纯净窗口（无视遮挡），应用原生圆角与 macOS 拟物多层柔和阴影，最后交付。
    func handleWindowCaptured(window: WindowInfo, snapshot: DisplaySnapshot) {
        Task { @MainActor in
            do {
                // 1. 优先使用 SCContentFilter 独立捕获纯净窗口内容（无视任何遮挡）
                let rawImage = try await capture.captureWindow(window)
                let finalImage = WindowEffects.applyWindowEffects(
                    to: rawImage,
                    shadowEnabled: settings.windowShadowEnabled,
                    shadowSize: settings.windowShadowSize,
                    scale: snapshot.effectiveScale
                )
                deliver(finalImage, onDisplay: snapshot.displayID)
            } catch {
                logger.warning(
                    "independent window capture failed: \(error.localizedDescription), falling back to screen crop"
                )
                // 2. 若独立捕获不可用（如特殊系统浮层），回退到底图截取并套用圆角与阴影
                let screen = NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID } ?? NSScreen.main!
                let localRect = DisplayGeometry.localRect(
                    fromCGRect: window.frameInCGPoints,
                    screen: screen
                ).intersection(CGRect(origin: .zero, size: screen.frame.size))
                if let cropped = CaptureOutput.crop(snapshot, toLocalRect: localRect) {
                    let finalImage = WindowEffects.applyWindowEffects(
                        to: cropped,
                        shadowEnabled: settings.windowShadowEnabled,
                        shadowSize: settings.windowShadowSize,
                        scale: snapshot.effectiveScale
                    )
                    deliver(finalImage, onDisplay: snapshot.displayID)
                } else {
                    presentCaptureFailure(error)
                }
            }
        }
    }

    /// 截图完成后的分流：原地编辑 / 浮窗预览。
    func handleCaptured(
        _ image: CGImage,
        onDisplay displayID: CGDirectDisplayID,
        screenRect: CGRect
    ) {
        switch settings.editorMode {
        case .inline:
            if settings.playShutterSound {
                CaptureOutput.playShutterSound()
            }
            // 截完立刻进剪贴板：原地编辑期间（甚至取消编辑）也能直接去别处粘贴。
            // 编辑器中点 ✓ 会再写一次，把带标注的成图覆盖上去。
            copyToClipboard(image)
            openInlineEditor(image, anchor: screenRect, allowsCrop: false)
        case .window:
            deliver(image, onDisplay: displayID)
        }
    }

    /// 按设置把成图写进剪贴板（关掉就不再写）。
    func copyToClipboard(_ image: CGImage) {
        guard settings.copyToClipboard else { return }
        if !CaptureOutput.copyToPasteboard(image) {
            logger.error("clipboard write failed")
        }
    }

    func deliver(_ image: CGImage, onDisplay displayID: CGDirectDisplayID) {
        logger.notice("delivering \(image.width)x\(image.height) capture")
        recordHistory(image)

        if settings.playShutterSound {
            CaptureOutput.playShutterSound()
        }
        copyToClipboard(image)
        if settings.saveToDisk {
            save(image)
        }

        quickAccess.autoCloseDelay = settings.quickAccessAutoCloseDelay
        quickAccess.position = settings.quickAccessPosition
        // 这次编辑是从某张浮窗卡片进来的：旧卡片让位，别让它留着没编辑过的那张
        // （用户看到的会是「裁了怎么还是原来那张」）。
        if let card = cardBeingEdited {
            cardBeingEdited = nil
            quickAccess.dismiss(card: card, animated: false)
        }
        quickAccess.present(
            image: image,
            onDisplay: displayID,
            saveDirectory: settings.saveDirectory
        )
    }

    /// 从浮窗（钉图或快速访问）恢复到原地编辑模式：图片在屏幕中央居中展示，下方出现工具栏。
    ///
    /// - Parameter allowsCrop: 给不给「裁剪」工具。**只有「已有的图片」才给**（浮窗卡片 / 钉图 /
    ///   历史记录）；刚截下来的画面不给——那块区域就是用户刚框出来的，再裁一次像是在重新框选区。
    /// - Parameter sourceCard: 从哪张浮窗卡片进来的（没有就 nil）。编辑确认后那张旧卡片要让位，
    ///   不然屏幕上留着没编辑过的那张，看着像「裁了没生效」。
    func openInlineEditor(
        _ image: CGImage,
        anchor: CGRect? = nil,
        allowsCrop: Bool,
        sourceCard: UUID? = nil
    ) {
        guard !overlays.isPresenting else { return }
        guard requireScreenCapturePermission() else { return }
        cardBeingEdited = sourceCard

        // 确定目标屏幕：优先包含 anchor 的屏幕，否则主屏幕
        let targetScreen: NSScreen
        if let anchor, anchor.width > 0, anchor.height > 0 {
            targetScreen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens.first!
        } else {
            targetScreen = NSScreen.main ?? NSScreen.screens.first!
        }

        Task { @MainActor in
            do {
                let snapshots = try await capture.captureAllDisplays()
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                let session = CaptureSession(snapshots: snapshots, windows: windows)
                overlays.present(
                    session: session,
                    inlineMode: true,
                    restoredImage: image,
                    targetScreen: targetScreen,
                    allowsCrop: allowsCrop
                )
            } catch {
                logger.error("failed to open inline editor: \(error.localizedDescription)")
                presentCaptureFailure(error)
            }
        }
    }

    func save(_ image: CGImage) {
        do {
            let url = try CaptureOutput.save(
                image,
                toDirectory: settings.saveDirectory,
                format: settings.saveFormat,
                quality: settings.jpegQuality,
                nameTemplate: settings.effectiveFilenameTemplate
            )
            didSave(to: url)
        } catch {
            logger.error("save failed: \(error.localizedDescription)")
        }
    }

    /// 「存储为…」：弹系统保存面板让用户选择位置。
    @discardableResult
    func saveAs(_ image: CGImage, ensuresHistory: Bool = false) -> Bool {
        let panel = NSSavePanel()
        panel.directoryURL = settings.saveDirectory
        panel.canCreateDirectories = true
        panel.allowedContentTypes = settings.saveFormat == .png ? [.png] : [.jpeg]
        let base = FilenameTemplate.makeName(
            template: settings.effectiveFilenameTemplate,
            date: Date()
        )
        panel.nameFieldStringValue = "\(base).\(settings.saveFormat.fileExtension)"

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let data: Data?
            switch settings.saveFormat {
            case .png: data = CaptureOutput.pngData(image)
            case .jpeg: data = CaptureOutput.jpegData(image, quality: settings.jpegQuality)
            }
            guard let data else { throw CaptureOutputError.encodingFailed }
            try data.write(to: url, options: .atomic)
            if ensuresHistory {
                recordHistory(image)
            }
            didSave(to: url)
            return true
        } catch {
            logger.error("save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 视频卡的「保存」：把成片**另存一份**到用户挑的地方。
    ///
    /// 与截图的「保存」同一个面板、同一个默认目录；差别是原片已经在保存目录里了，
    /// 所以这是**复制**（原片留着，卡片上的播放 / 在访达中显示 / 拖拽都还指着它）。
    func saveVideoAs(_ url: URL) {
        let panel = NSSavePanel()
        panel.directoryURL = settings.saveDirectory
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // 选到原片自己：什么都不做（绝不允许「先删目标再拷」把自己删了）。
        guard destination.standardizedFileURL != url.standardizedFileURL else { return }
        do {
            // 面板已经确认过「替换」，这里先清掉同名文件再拷。
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            logger.notice("recording saved as: \(destination.lastPathComponent)")
        } catch {
            logger.error("save recording as failed: \(error.localizedDescription)")
        }
    }

    /// 落盘后的统一收尾：记入最近截图 + 系统通知。
    func didSave(to url: URL) {
        // 历史那条记上「用户的文件在哪」：打开 / 在访达中显示都该落到它上面。
        HistoryStore.shared.attachSavedFile(url, to: HistoryStore.shared.latestID)
        settings.recordCapture(url)
        logger.notice("saved capture to \(url.path, privacy: .public)")
        if settings.showSaveNotification {
            notifier.notifySaved(fileURL: url)
        }
    }

    /// 打开历史某一项进入标注（居中原地编辑）。
    func openHistoryItem(_ item: HistoryItem) {
        if let cgImage = item.cgImage {
            openInlineEditor(cgImage, allowsCrop: true)
            return
        }
        guard let url = item.url,
            let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        openInlineEditor(cgImage, allowsCrop: true)
    }

    /// 清空所有历史与最近记录。
    func clearAllHistory() {
        settings.clearRecentCaptures()
        HistoryStore.shared.removeAll()
        HistoryThumbnailCache.shared.clear()
    }



    /// 会话内截图（最新在前）+ 磁盘上保存过的截图，按时间倒序且按路径去重。
    func historyItems() -> [HistoryItem] {
        var seenURLs = Set<URL>()
        var result: [HistoryItem] = []

        // 落盘历史：唯一的那份（重启后全靠它）。
        for entry in HistoryStore.shared.entries {
            let url = entry.displayURL
            guard !seenURLs.contains(url) else { continue }
            seenURLs.insert(url)
            result.append(
                HistoryItem(
                    id: entry.id,
                    date: entry.date,
                    image: HistoryThumbnailCache.shared.image(for: url),
                    url: url,
                    cgImage: nil
                )
            )
        }

        // 更早的「保存到磁盘」留下的文件（这个功能之前就用它列）：还认得出来的也列上。
        for url in settings.recentCaptureURLs {
            guard !seenURLs.contains(url) else { continue }
            seenURLs.insert(url)
            result.append(
                HistoryItem(
                    id: url.path,
                    date: FilenameTemplate.captureDate(of: url),
                    image: HistoryThumbnailCache.shared.image(for: url),
                    url: url,
                    cgImage: nil
                )
            )
        }

        return result
            .sorted { $0.date > $1.date }
            .prefix(40)
            .map { $0 }
    }

    /// 记录一次截图到「最近截图」历史。
    ///
    /// **只有这一份**（`HistoryStore`）：以前这里还另存一份内存里的会话历史，于是同一次截图
    /// 会在菜单里出现两次（未保存的那份没有 url，按 url 去重根本抓不住它）。
    func recordHistory(_ image: CGImage) {
        HistoryStore.shared.record(image)
    }

    /// 打开截图保存目录（不存在则先创建）。
    func openSaveFolder() {
        let directory = settings.saveDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(directory)
        } catch {
            logger.error("open save folder failed: \(error.localizedDescription)")
        }
    }

    /// 启动时把「登录时启动」状态同步给系统，避免设置与系统实际状态不一致。
    func setUpLaunchAtLogin() {
        LaunchAtLogin.setEnabled(settings.launchAtLogin)
    }
}
