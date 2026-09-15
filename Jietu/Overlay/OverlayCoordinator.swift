import AppKit
import os

/// 每个显示器一个遮罩窗，统一由它创建 / 撤销 / 汇总结果。
final class OverlayCoordinator {
    enum Outcome {
        case cancelled
        /// `annotated` 为 true 表示已在遮罩里就地标注过，不再走编辑器。
        case captured(
            image: CGImage,
            displayID: CGDirectDisplayID,
            screenRect: CGRect,
            annotated: Bool
        )
    }

    private let logger = Logger(subsystem: "com.liwenjiao.jietu", category: "overlay")
    private var controllers: [OverlayWindowController] = []
    private var session: CaptureSession?
    private var escapeMonitor: Any?
    /// 遮罩期间被打断的前台 App，结束后还给它。
    private var previousApplication: NSRunningApplication?

    var onFinish: ((Outcome) -> Void)?
    /// 就地工具栏的下载 / 钉图。
    var onSaveImage: ((CGImage) -> Void)?
    /// 钉图（参数二是屏幕坐标矩形，用于原地钉）。
    var onPinImage: ((CGImage, CGRect) -> Void)?

    var isPresenting: Bool { !controllers.isEmpty }

    func present(session: CaptureSession, inlineMode: Bool) {
        guard !isPresenting else { return }
        guard !session.snapshots.isEmpty else { return }

        self.session = session
        previousApplication = NSWorkspace.shared.frontmostApplication

        let screens = NSScreen.screens
        for (index, snapshot) in session.snapshots.enumerated() {
            guard
                let screen = screens.first(where: { $0.jietu_displayID == snapshot.displayID })
            else { continue }

            let controller = OverlayWindowController(
                snapshot: snapshot,
                session: session,
                screen: screen,
                displayIndex: index + 1,
                displayCount: session.snapshots.count,
                inlineMode: inlineMode
            )
            controller.onCancel = { [weak self] in
                self?.finish(.cancelled, reason: "canvas:cancel")
            }
            controller.onCommit = { [weak self] localRect in
                self?.commit(snapshot: snapshot, localRect: localRect)
            }
            controller.onCommitAnnotated = { [weak self] image, rect in
                self?.commitAnnotated(image: image, snapshot: snapshot, localRect: rect)
            }
            controller.onSaveImage = { [weak self] image in
                self?.onSaveImage?(image)
            }
            controller.onPinImage = { [weak self] image, localRect in
                guard let self else { return }
                let rect = self.screenRect(forLocalRect: localRect, snapshot: snapshot)
                self.onPinImage?(image, rect)
                self.finish(.cancelled, reason: "pin")
            }
            controllers.append(controller)
        }

        guard !controllers.isEmpty else {
            logger.error("no overlay controllers created")
            return
        }

        // Esc 兜底：焦点可能落在另一块屏的遮罩窗上。
        // 注意：这里绝不能记录按键内容。就地标注阶段交给画布自己处理 Esc。
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPresenting else { return event }
            if event.keyCode == 53 {
                if self.controllers.contains(where: { $0.isInlineEditing }) {
                    return event
                }
                self.finish(.cancelled, reason: "escapeMonitor")
                return nil
            }
            return event
        }

        // 必须激活 App 才会收到 mouseMoved（hover 高亮与放大镜都依赖它）。
        // 代价是打断前台 App，所以 finish 时会把焦点还回去。
        // 另外注：`.nonactivatingPanel` 挡不住这个需求，不激活时 mouseMoved 根本不投递。
        NSApp.activate()
        for controller in controllers {
            controller.show()
        }

        // 初始焦点给鼠标所在的那块屏，这样 ↵ / 方向键一开始就作用在正确的显示器上。
        let mouseLocation = NSEvent.mouseLocation
        let focused = controllers.first { $0.screenFrame.contains(mouseLocation) }
            ?? controllers.first
        focused?.focus()
    }

    func cancel() {
        finish(.cancelled, reason: "external")
    }

    private func commit(snapshot: DisplaySnapshot, localRect: CGRect) {
        guard let image = CaptureOutput.crop(snapshot, toLocalRect: localRect) else {
            logger.error("crop produced empty image")
            finish(.cancelled, reason: "crop-failed")
            return
        }
        let screenRect = screenRect(forLocalRect: localRect, snapshot: snapshot)
        finish(
            .captured(
                image: image,
                displayID: snapshot.displayID,
                screenRect: screenRect,
                annotated: false
            ),
            reason: "commit"
        )
    }

    /// 就地标注确认：画布已经给了烘焙好标注的最终图。
    private func commitAnnotated(image: CGImage, snapshot: DisplaySnapshot, localRect: CGRect) {
        let screenRect = screenRect(forLocalRect: localRect, snapshot: snapshot)
        finish(
            .captured(
                image: image,
                displayID: snapshot.displayID,
                screenRect: screenRect,
                annotated: true
            ),
            reason: "commit-annotated"
        )
    }

    private func screenRect(forLocalRect localRect: CGRect, snapshot: DisplaySnapshot) -> CGRect {
        let screen = NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID }
            ?? NSScreen.main
        let origin = screen.map {
            DisplayGeometry.appKitPoint(fromLocal: localRect.origin, screen: $0)
        } ?? localRect.origin
        return CGRect(origin: origin, size: localRect.size)
    }

    private func finish(_ outcome: Outcome, reason: String) {
        guard isPresenting else { return }
        logger.notice("overlay finish reason=\(reason, privacy: .public)")

        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        for controller in controllers {
            controller.close()
        }
        controllers.removeAll()
        session = nil

        // 把焦点还给用户原本在用的 App，别让截图打断工作流。
        // （Quick Access 面板是非激活的，所以仍然浮在上面。）
        if let previousApplication, previousApplication.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication.activate()
        }
        previousApplication = nil

        onFinish?(outcome)
    }

    #if DEBUG
    /// 自检用：每个遮罩当前的选区。
    var debugSelections: [(displayID: CGDirectDisplayID, localRect: CGRect?)] {
        controllers.map { ($0.snapshot.displayID, $0.debugSelection) }
    }

    /// 自检用：把每个遮罩窗自己认为的 AppKit frame 报出来。
    var debugWindowFrames: [(
        displayID: CGDirectDisplayID,
        frame: CGRect,
        level: Int,
        isKey: Bool,
        firstResponderClass: String
    )] {
        controllers.map {
            (
                displayID: $0.snapshot.displayID,
                frame: $0.window.frame,
                level: $0.window.level.rawValue,
                isKey: $0.window.isKeyWindow,
                firstResponderClass: String(describing: type(of: $0.window.firstResponder))
            )
        }
    }
    #endif
}
