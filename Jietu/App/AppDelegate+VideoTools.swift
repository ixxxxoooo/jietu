import AppKit
import UniformTypeIdentifiers

/// AppDelegate — 成片的两个「再加工」入口：裁剪与导出 GIF。
///
/// 两者都从浮窗视频卡进来（`onTrimVideo` / `onExportGif`），产物都是**另存的新文件**，
/// 原片一概不动——用户录了半天的东西，不该因为我们多做一步加工就丢了。
///
/// @author ixxxxoooo
extension AppDelegate {

    /// 视频卡「裁剪…」：开一个裁剪窗口（播放器 + 双柄时间轴）。
    ///
    /// 同时只允许一个：窗口已经开着就把它提到前面（不然重复点会开出一堆窗口）。
    func openVideoTrim(_ url: URL) {
        if let existing = videoTrimController {
            existing.present(on: screenForVideoWindow())
            return
        }
        let controller = VideoTrimController(url: url)
        controller.onExported = { [weak self] destination in
            self?.logger.notice("trimmed recording saved: \(destination.lastPathComponent)")
            if self?.settings.showSaveNotification ?? true {
                self?.notifier.notifyExported(fileURL: destination, title: "裁剪完成")
            }
        }
        controller.onClose = { [weak self] in
            self?.videoTrimController = nil
        }
        videoTrimController = controller
        controller.present(on: screenForVideoWindow())
    }

    /// 视频卡「导出 GIF…」：选好落点后转一份动图，期间用浮窗报进度。
    ///
    /// 转码在后台跑（`GifExporter` 内部起 detached task），完成才收进度浮窗并发通知；
    /// 失败弹窗说明原因（没视频轨 / 磁盘满 / 没权限）。
    func exportVideoAsGif(_ url: URL) {
        let panel = NSSavePanel()
        // 默认落在用户设的保存目录（不是源 mp4 所在目录）：那才是「我的东西放哪」的答案。
        panel.directoryURL = settings.saveDirectory
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "\(url.deletingPathExtension().lastPathComponent).gif"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // 选到源文件自己：拒绝（GIF 覆盖掉 mp4 就糟了）。
        guard destination.standardizedFileURL != url.standardizedFileURL else { return }

        let hud = GifExportPanel()
        hud.present(on: screenForVideoWindow())
        gifExportPanel = hud
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        Task { @MainActor in
            do {
                try await GifExporter.export(from: url, to: destination) { fraction in
                    Task { @MainActor in hud.update(fraction: fraction) }
                }
                hud.close()
                gifExportPanel = nil
                logger.notice("gif exported: \(destination.lastPathComponent)")
                if settings.showSaveNotification {
                    notifier.notifyExported(fileURL: destination, title: "GIF 已导出")
                }
            } catch {
                hud.close()
                gifExportPanel = nil
                presentGifFailure(error)
            }
        }
    }

    /// 视频相关窗口落在哪块屏：鼠标当前所在的那块（和录屏浮窗同一套口径）。
    private func screenForVideoWindow() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func presentGifFailure(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "没能导出 GIF"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
