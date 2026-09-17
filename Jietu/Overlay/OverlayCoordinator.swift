import AppKit
import os

/// 每个显示器一个遮罩窗，统一由它创建 / 撤销 / 汇总结果。
final class OverlayCoordinator {
    enum Outcome {
        case cancelled
        /// `annotated` 为 true 表示已在遮罩里原地标注过，不再走编辑器。
        case captured(
            image: CGImage,
            displayID: CGDirectDisplayID,
            screenRect: CGRect,
            annotated: Bool
        )
        /// 用户点选了某个窗口，要求独立高质量捕获（套用圆角与阴影）。
        case windowCaptured(
            window: WindowInfo,
            snapshot: DisplaySnapshot
        )
    }

    private let logger = Logger(subsystem: "com.ixxxxoooo.jietu", category: "overlay")
    private var controllers: [OverlayWindowController] = []
    private var session: CaptureSession?
    private var escapeMonitor: Any?
    /// 遮罩期间被打断的前台 App，结束后还给它。
    private var previousApplication: NSRunningApplication?

    var onFinish: ((Outcome) -> Void)?
    /// 原地工具栏的下载 / 钉图。
    var onSaveImage: ((CGImage) -> Void)?
    /// 钉图（参数二是屏幕坐标矩形，用于原地钉）。
    var onPinImage: ((CGImage, CGRect) -> Void)?
    /// 原地标注的默认样式（present 时传给工具栏；改动后经 `onAnnotationDefaultsChange` 回报）。
    var annotationDefaults: AnnotationDefaults = .standard
    var onAnnotationDefaultsChange: ((AnnotationDefaults) -> Void)?

    /// 遮罩的用途：普通截图 / 专选窗口截图 / 只要一块选区（滚动长图起步用）。
    enum Purpose {
        case screenshot
        case windowCapture
        case regionPick
    }

    /// 遮罩这一次要干什么（截图 / 只要一个矩形）。**用完即复位**，见 `finish()`。
    var purpose: Purpose = .screenshot
    /// `purpose == .regionPick` 时：鼠标在选区上停住（或松手）→ 选区 local 矩形。
    /// 外面据此把「手动 / 自动」浮到选框下方。
    var onSelectionPaused: ((DisplaySnapshot, CGRect) -> Void)?
    /// `purpose == .regionPick` 时：选区被拖 / 缩放 / 清空（nil）→ 控制条跟着走。
    var onSelectionChanged: ((DisplaySnapshot, CGRect?) -> Void)?

    /// 滚动长图期间遮罩**不关**：只留压暗 + 绿框当取景框（鼠标穿透）。
    private var isHoldingForScrollCapture = false

    var isPresenting: Bool { !controllers.isEmpty }

    /// 临时隐藏 / 恢复所有遮罩窗（例如弹系统保存面板时，否则会被遮罩挡住）。
    func setOverlayHidden(_ hidden: Bool) {
        for controller in controllers {
            if hidden {
                controller.window.orderOut(nil)
            } else {
                controller.window.orderFrontRegardless()
            }
        }
    }

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
                inlineMode: inlineMode,
                annotationDefaults: annotationDefaults
            )
            controller.onCancel = { [weak self] in
                self?.finish(.cancelled, reason: "canvas:cancel")
            }
            // 滚动长图起步：选区不急着交付，鼠标停住就交给外面的控制条。
            controller.isRegionPickMode = (purpose == .regionPick)
            // 专选窗口模式（直接高亮并选窗）
            controller.isWindowOnlyMode = (purpose == .windowCapture)
            controller.onWindowSelected = { [weak self] window in
                self?.finish(
                    .windowCaptured(window: window, snapshot: snapshot),
                    reason: "window-selected"
                )
            }
            controller.onSelectionPaused = { [weak self] localRect in
                self?.onSelectionPaused?(snapshot, localRect)
            }
            controller.onSelectionChanged = { [weak self] localRect in
                self?.onSelectionChanged?(snapshot, localRect)
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
            controller.onAnnotationDefaultsChange = { [weak self] updated in
                self?.annotationDefaults = updated
                self?.onAnnotationDefaultsChange?(updated)
            }
            controllers.append(controller)
        }

        guard !controllers.isEmpty else {
            logger.error("no overlay controllers created")
            return
        }

        // Esc 兜底：焦点可能落在另一块屏的遮罩窗上。
        // 注意：这里绝不能记录按键内容。原地标注阶段交给画布自己处理 Esc。
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

    /// 原地标注确认：画布已经给了烘焙好标注的最终图。
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

    /// 滚动长图取景：遮罩留着、切成取景框外观、鼠标穿透，并把前台还给用户原来的 App。
    ///
    /// 由外部在用户**真的选了「手动 / 自动」之后**调用——在那之前用户还能继续调选区。
    func beginScrollCaptureChrome() {
        holdForScrollCapture()
    }

    /// 滚动长图取景：遮罩留着、切成取景框外观、鼠标穿透，并把前台还给用户原来的 App。
    private func holdForScrollCapture() {
        guard isPresenting, !isHoldingForScrollCapture else { return }
        isHoldingForScrollCapture = true
        for controller in controllers {
            controller.enterScrollCaptureChrome()
        }
        // 页面得能滚：把前台还给用户原本在用的 App。
        if let previousApplication,
            previousApplication.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            previousApplication.activate()
        }
        previousApplication = nil
    }

    /// 滚动长图结束：这时候才真正关掉遮罩。
    func releaseScrollChrome() {
        guard isHoldingForScrollCapture else { return }
        isHoldingForScrollCapture = false
        finish(.cancelled, reason: "scroll-capture-released")
    }

    private func finish(_ outcome: Outcome, reason: String) {
        guard isPresenting else { return }
        // 用途用完即复位，调用方不必记着清：
        // 否则「滚动长图取消选区」会把 .regionPick 留下，下一次普通区域截图误走滚动长图。
        defer { purpose = .screenshot }
        logger.notice("overlay finish reason=\(reason, privacy: .public)")

        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        isHoldingForScrollCapture = false
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

    /// 自检用：跳过鼠标，直接给某块屏摆一个选区。
    func debugSetSelection(_ localRect: CGRect, displayID: CGDirectDisplayID) {
        controllers.first { $0.snapshot.displayID == displayID }?
            .debugSetSelection(localRect)
    }

    /// 自检用：指定屏上放大镜的模型 / 呈现 frame。
    func debugLoupePresentation(
        displayID: CGDirectDisplayID
    ) -> (model: CGRect, presentation: CGRect?, isHidden: Bool)? {
        controllers.first { $0.snapshot.displayID == displayID }?.debugLoupePresentation
    }

    /// 自检用：指定屏上放大镜的采样窗口 / 光标格子。
    func debugLoupeState(displayID: CGDirectDisplayID) -> OverlayCanvasView.DebugLoupeState? {
        controllers.first { $0.snapshot.displayID == displayID }?.debugLoupeState
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
