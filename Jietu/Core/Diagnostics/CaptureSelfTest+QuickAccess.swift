import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 浮窗图标（Quick Access）响应速度自检。
///
/// @author ixxxxoooo
extension CaptureSelfTest {
    /// 浮窗自检期间必须有人持有面板，否则窗口会被立刻释放。
    static var retainedQuickAccess: QuickAccessPanelController?

    /// 浮窗图标自检：真弹一张浮窗、真注入点击，逐图标量响应速度。
    ///
    /// 「灵敏」拆成四段分别量，哪一段慢了一看就知道：
    /// 1. 按下 → 按下反馈（控件自己记，正常 < 1ms）；
    /// 2. 按下 → 动作闭包（AppKit 派发）；
    /// 3. 按下 → 可见效果（关窗 / 钉图窗口出现 / 编辑器出现 / 落盘 / 写剪贴板）；
    /// 4. **光标甩过去就点**（不等图标淡入）——浮窗图标最容易在这里点空。
    ///
    /// 历史教训：双击手势识别器会把单击压后一个双击间隔（实测关窗晚 ~520ms），
    /// 肉眼看就是「钝」。这条自检就是防它回来。
    static func runQuickAccessTest(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            /// 每段延迟的预算：超了就 FAIL。
            var budgets: [(label: String, milliseconds: Double?, limit: Double)] = []
            do {
                InteractionMetrics.reset()
                InteractionMetrics.enable()
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )
                guard let screen = NSScreen.main, let displayID = screen.jietu_displayID
                else { throw CaptureError.noDisplays }

                let image = try makeTestImage(width: 800, height: 600)
                let cardSize = QuickAccessView.panelSize(
                    for: CGSize(width: image.width, height: image.height)
                )
                report.append(
                    "浮窗卡片 \(Int(cardSize.width))x\(Int(cardSize.height))"
                        + "（图 \(image.width)x\(image.height)px）"
                )

                // 探针：把「动作真的发生了吗」变成可观察的信号。
                // 记**应用内时刻**（`CACurrentMediaTime`）：注入事件的投递抖动（实测 1~90ms）
                // 是注入管线的账，不该算到界面头上，所以效果延迟一律从动作那一刻起算。
                var fired: [(name: String, at: CFAbsoluteTime)] = []
                @MainActor func fire(_ name: String) {
                    fired.append((name, CACurrentMediaTime()))
                }
                var dismissed = 0
                var savedFile: URL?
                var pasteboardDelta = 0

                let controller = QuickAccessPanelController()
                controller.autoCloseDelay = 0  // 自检期间不许自动关
                controller.position = .bottomRight
                controller.onDismiss = { dismissed += 1 }
                controller.onCopy = { image in
                    let before = NSPasteboard.general.changeCount
                    CaptureOutput.copyToPasteboard(image)
                    pasteboardDelta = NSPasteboard.general.changeCount - before
                    fire("复制")
                }
                controller.onSave = { image in
                    let url = outputDirectory.appendingPathComponent("quickaccess-save.png")
                    try? CaptureOutput.pngData(image)?.write(to: url)
                    savedFile = FileManager.default.fileExists(atPath: url.path) ? url : nil
                    fire("保存")
                }
                controller.onPin = { image in
                    PinWindowController.pin(image: image, on: screen)
                    fire("钉图")
                }
                controller.onAnnotate = { _, _ in
                    fire("标注")
                }
                retainedQuickAccess = controller
                controller.present(
                    image: image,
                    onDisplay: displayID,
                    saveDirectory: outputDirectory
                )
                try? await Task.sleep(for: .milliseconds(700))
                guard let panel = controller.panelsForTesting.first,
                    let contentView = panel.contentView,
                    let controls = findControlsView(in: contentView)
                else {
                    report.append("error: 浮窗 / 控件层没有出现")
                    report.append("RESULT: FAIL")
                    finish(report, code: 1)
                    return
                }
                report.append("卡片 frame=\(describe(panel.frame)) 图标层=\(controls)")

                // ---- 取点 / 注入工具 ----

                /// 面板局部坐标（原点左下）→ cg 屏幕坐标（原点主屏左上）。
                @MainActor func cgPoint(local point: CGPoint, of panel: NSPanel) -> CGPoint {
                    let appKit = CGPoint(
                        x: panel.frame.minX + point.x, y: panel.frame.minY + point.y
                    )
                    return DisplayGeometry.cgPoint(
                        fromLocal: CGPoint(
                            x: appKit.x - screen.frame.minX, y: appKit.y - screen.frame.minY
                        ),
                        screen: screen
                    )
                }

                @MainActor func iconPoint(_ action: QuickAccessAction, of panel: NSPanel) -> CGPoint {
                    let rect = QuickAccessControlsView.frame(of: action, in: cardSize)
                    return cgPoint(local: CGPoint(x: rect.midX, y: rect.midY), of: panel)
                }

                /// 卡片本体上的一点（避开四角圆盘与中间胶囊）：验证「点击进标注」照旧。
                @MainActor func bodyPoint(of panel: NSPanel) -> CGPoint {
                    cgPoint(local: CGPoint(x: cardSize.width / 2, y: cardSize.height * 0.26), of: panel)
                }

                /// 卡片外侧的一点：把光标挪开，才谈得上「进入」。
                @MainActor func awayPoint(of panel: NSPanel) -> CGPoint {
                    cgPoint(local: CGPoint(x: -60, y: cardSize.height / 2), of: panel)
                }

                @MainActor func controlsOf(_ panel: NSPanel) -> QuickAccessControlsView? {
                    panel.contentView.flatMap { findControlsView(in: $0) }
                }

                @MainActor func alphas(of panel: NSPanel) -> [CGFloat] {
                    guard let controls = controlsOf(panel) else { return [] }
                    return QuickAccessAction.imageCard.map { controls.button(for: $0)?.alphaValue ?? -1 }
                }

                /// 图标**真正画出来**的透明度（含 0.12s 淡入动画，不是模型值）。
                @MainActor func presentationAlphas(of panel: NSPanel) -> [CGFloat] {
                    guard let controls = controlsOf(panel) else { return [] }
                    return QuickAccessAction.imageCard.map { action in
                        let button = controls.button(for: action)
                        let presented = button?.layer?.presentation()?.opacity
                        return CGFloat(presented ?? Float(button?.alphaValue ?? -1))
                    }
                }

                @MainActor func waitFrom(
                    _ since: CFAbsoluteTime, timeout: TimeInterval = 2,
                    until condition: () -> Bool
                ) async -> Double? {
                    while CACurrentMediaTime() - since < timeout {
                        if condition() { return (CACurrentMediaTime() - since) * 1000 }
                        try? await Task.sleep(for: .milliseconds(4))
                    }
                    return nil
                }

                /// 从**动作真正发生**那一刻起，等到某个可见效果出现（毫秒）。
                /// 传 nil 表示那次动作根本没发生（点空了）。
                @MainActor func effectMs(
                    _ action: String, timeout: TimeInterval = 3, until condition: () -> Bool
                ) async -> Double? {
                    guard let at = fired.last(where: { $0.name == action })?.at else { return nil }
                    return await waitFrom(at, timeout: timeout, until: condition)
                }

                /// 挪光标。`CGWarpMouseCursorPosition` 兜底：**注入的 move 事件偶尔完全不生效**
                /// （钉图自检里那段「第 N 次注入后按钮还是没出来，重试」就是同一个坑）。
                @MainActor func moveMouse(to point: CGPoint) {
                    CGWarpMouseCursorPosition(point)
                    postMouse(.mouseMoved, at: point)
                }

                /// 挪到某点并**确认浮窗已收到悬停**，再留 150ms 让图标淡完。
                /// 返回是否确认成功——注入会丢，丢了就得重试，否则后面量的是「点空」而不是延迟。
                @MainActor func hover(_ point: CGPoint, of panel: NSPanel) async -> Bool {
                    let away = awayPoint(of: panel)
                    for _ in 0..<4 {
                        moveMouse(to: away)
                        try? await Task.sleep(for: .milliseconds(90))
                        moveMouse(to: point)
                        let confirmed = await waitFrom(CACurrentMediaTime(), timeout: 0.3) {
                            controlsOf(panel)?.isHovering == true
                        }
                        if confirmed != nil {
                            try? await Task.sleep(for: .milliseconds(150))  // 等淡入（0.12s）
                            return true
                        }
                    }
                    return false
                }

                /// 注入一次真实点击（60ms 按住时长，普通点击的节奏）。
                ///
                /// 这一节统一用 `CACurrentMediaTime()`（开机秒数）：`CFAbsoluteTimeGetCurrent()`
                /// 是 2001 起算的另一个基准，两者相减会得出几十年的时间差。
                @MainActor func press(_ point: CGPoint) async -> (press: CFAbsoluteTime, release: CFAbsoluteTime) {
                    let pressAt = CACurrentMediaTime()
                    postMouse(.leftMouseDown, at: point)
                    try? await Task.sleep(for: .milliseconds(60))
                    let releaseAt = CACurrentMediaTime()
                    postMouse(.leftMouseUp, at: point)
                    return (pressAt, releaseAt)
                }

                /// 新弹一张浮窗并**热身**，返回它的面板。
                ///
                /// 热身是必要的：新面板的第一次交互要付首帧渲染的账（实测第一下点击会多出
                /// 60~80ms 的系统投递延迟，第二次起就没有）。这里把五个图标各悬停一遍走掉它，
                /// 后面量到的才是点击链路本身，而不是「新窗口第一帧」。
                @MainActor func presentPanel() async -> NSPanel? {
                    controller.present(
                        image: image, onDisplay: displayID, saveDirectory: outputDirectory
                    )
                    try? await Task.sleep(for: .milliseconds(700))
                    guard let panel = controller.panelsForTesting.last else { return nil }
                    for action in QuickAccessAction.imageCard {
                        moveMouse(to: iconPoint(action, of: panel))
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    moveMouse(to: bodyPoint(of: panel))
                    try? await Task.sleep(for: .milliseconds(120))
                    moveMouse(to: awayPoint(of: panel))
                    try? await Task.sleep(for: .milliseconds(200))
                    return panel
                }

                // 1. 静息态：图标应当全部隐形。
                moveMouse(to: awayPoint(of: panel))
                try? await Task.sleep(for: .milliseconds(300))
                report.append("静息态透明度 \(describe(alphas(of: panel)))（期望全 0）")

                // 2. 悬停：图标淡入，截图给人看风格是不是和钉图一套。
                let hoverConfirmed = await hover(bodyPoint(of: panel), of: panel)
                report.append(
                    "悬停确认=\(hoverConfirmed ? "是" : "否")"
                        + "（图标实际透明度已到 \(describe(presentationAlphas(of: panel)))）"
                )
                let hoverShots = try await CaptureEngine().captureAllDisplays(
                    excludingOwnApplication: false
                )
                if let shot = hoverShots.first(where: { $0.displayID == displayID })
                    ?? hoverShots.first
                {
                    let url = outputDirectory.appendingPathComponent("quickaccess-hover.png")
                    try writePNG(shot.image, to: url)
                    report.append("悬停态截图 -> \(url.path)")
                }

                // 3. 三个不销毁浮窗的图标：先悬停再点。
                //    「按下→动作」用墙钟（含 60ms 按住 + 注入投递抖动，只作参考）；
                //    「动作→效果」从**动作发生那一刻**起算（应用内时钟），并据此判 PASS/FAIL。
                for action in [QuickAccessAction.save, .copy, .pin] {
                    let before = fired.count
                    let confirmed = await hover(iconPoint(action, of: panel), of: panel)
                    let click = await press(iconPoint(action, of: panel))
                    let wallMs = await waitFrom(click.press) { fired.count > before }
                    let effect: Double?
                    switch action {
                    case .save:
                        effect = await effectMs(action.title) { savedFile != nil }
                    case .copy:
                        effect = await effectMs(action.title) { pasteboardDelta > 0 }
                    default:
                        effect = await effectMs(action.title) {
                            NSApp.windows.contains { $0 is PinPanel && $0.isVisible }
                        }
                    }
                    report.append(
                        String(
                            format: "    %@（悬停确认=%@）：按下→动作 %@（墙钟，含 60ms 按住），动作→%@ %@",
                            action.title,
                            confirmed ? "是" : "否",
                            describe(milliseconds: wallMs),
                            effectLabel(for: action),
                            describe(milliseconds: effect)
                        )
                    )
                    budgets.append(
                        ("\(action.title)·动作→\(effectLabel(for: action))", effect, effectLimit(for: action))
                    )
                }


                // 4. 光标甩过去就点关闭（不等悬停）：不能点空，更不能点成「标注」，
                //    顺带把「按下 → 开始侧滑 / 面板消失 / 回调」量出来。
                let fastBefore = fired.count
                let startX = panel.frame.minX
                moveMouse(to: awayPoint(of: panel))
                try? await Task.sleep(for: .milliseconds(250))
                let fastPoint = iconPoint(.close, of: panel)
                moveMouse(to: fastPoint)
                let fastClick = await press(fastPoint)
                let slideMs = await waitFrom(fastClick.release) { panel.frame.minX != startX }
                let goneMs = await waitFrom(fastClick.release, timeout: 3) { !panel.isVisible }
                let dismissedMs = await waitFrom(fastClick.release, timeout: 3) { dismissed > 0 }
                let misfired = fired.count > fastBefore ? fired.last?.name : nil
                report.append(
                    String(
                        format: "甩过去就点关闭（不等悬停）→ %@；抬起→开始侧滑 %@，→面板消失 %@，→回调 %@",
                        misfired.map { "误触发「\($0)」" } ?? "关掉了",
                        describe(milliseconds: slideMs),
                        describe(milliseconds: goneMs),
                        describe(milliseconds: dismissedMs)
                    )
                )
                budgets.append(("甩过去就点·关闭", misfired == nil ? goneMs : nil, 600))
                budgets.append(("关闭·开始侧滑", slideMs, 120))

                // 5. 新浮窗上点「标注」：它会先销毁浮窗再开编辑器。
                guard let annotatePanel = await presentPanel() else {
                    report.append("error: 浮窗没有出现")
                    report.append("RESULT: FAIL")
                    finish(report, code: 1)
                    return
                }
                let annotateBefore = fired.count
                let annotateHover = await hover(iconPoint(.annotate, of: annotatePanel), of: annotatePanel)
                let annotateClick = await press(iconPoint(.annotate, of: annotatePanel))
                let annotateWall = await waitFrom(annotateClick.press) { fired.count > annotateBefore }
                let annotateMs = await effectMs("标注") { fired.contains { $0.name == "标注" } }
                report.append(
                    String(
                        format: "    标注（悬停确认=%@）：按下→动作 %@（墙钟，含 60ms 按住），动作响应 %@",
                        annotateHover ? "是" : "否",
                        describe(milliseconds: annotateWall),
                        describe(milliseconds: annotateMs)
                    )
                )
                budgets.append(("标注·动作触发响应", annotateMs, effectLimit(for: .annotate)))

                // 6. 新浮窗上「卡片本体」甩过去就点（不等悬停）：应当进标注，而不是点空。
                guard let bodyPanel = await presentPanel() else {
                    report.append("error: 浮窗没有出现")
                    report.append("RESULT: FAIL")
                    finish(report, code: 1)
                    return
                }
                moveMouse(to: awayPoint(of: bodyPanel))
                try? await Task.sleep(for: .milliseconds(250))
                let tapBefore = fired.count
                let tapPoint = bodyPoint(of: bodyPanel)
                moveMouse(to: tapPoint)
                let tapClick = await press(tapPoint)
                let tapMs = await waitFrom(tapClick.press, timeout: 2) { fired.count > tapBefore }
                let tapAction = fired.count > tapBefore ? (fired.last?.name ?? "?") : "什么都没发生"
                report.append(
                    String(
                        format: "卡片本体甩过去就点（不等悬停）→ %@ %@",
                        tapAction,
                        describe(milliseconds: tapMs)
                    )
                )
                budgets.append(("卡片本体单击", tapMs, 250))

                // 7. 极端宽高比：卡片按最小尺寸兜底，图标不能互相压住（并留一张截图给人看）。
                // 第三张是「很小的图」：不该被放大（用户报过小图被撑大）。
                let extremes = [
                    CGSize(width: 700, height: 2800),
                    CGSize(width: 4000, height: 100),
                    CGSize(width: 40, height: 24),
                ]
                for size in extremes {
                    guard let extreme = try? makeTestImage(width: Int(size.width), height: Int(size.height))
                    else { continue }
                    let card = QuickAccessView.panelSize(for: size)
                    controller.present(
                        image: extreme, onDisplay: displayID, saveDirectory: outputDirectory
                    )
                    try? await Task.sleep(for: .milliseconds(700))
                    guard let panel = controller.panelsForTesting.last else { continue }

                    let frames = QuickAccessAction.imageCard.map {
                        ($0.title, QuickAccessControlsView.frame(of: $0, in: card))
                    }
                    var overlapped: [String] = []
                    for (index, first) in frames.enumerated() {
                        for second in frames[(index + 1)...] where first.1.intersects(second.1) {
                            overlapped.append("\(first.0)×\(second.0)")
                        }
                    }
                    let outside = frames.filter {
                        $0.1.minX < -0.001 || $0.1.minY < -0.001
                            || $0.1.maxX > card.width + 0.001 || $0.1.maxY > card.height + 0.001
                    }.map(\.0)

                    // 悬停点要按**这张卡**的尺寸算（外层那个 `bodyPoint` 用的是标准卡的尺寸，
                    // 在 96 宽的卡上会落到卡片外面）。并且要「先出去再进来」：卡片刚弹出时
                    // 光标可能本来就在卡片里，那样不产生 mouseEntered，按钮不会浮出来。
                    let extremeBody = cgPoint(
                        local: CGPoint(x: card.width / 2, y: card.height * 0.26), of: panel
                    )
                    _ = await hover(extremeBody, of: panel)
                    report.append(
                        "极端 \(Int(size.width))×\(Int(size.height))px → 卡片 "
                            + "\(Int(card.width))×\(Int(card.height))：图标重叠="
                            + (overlapped.isEmpty ? "无" : "**\(overlapped.joined(separator: "、"))**")
                            + "，越界=" + (outside.isEmpty ? "无" : "**\(outside.joined(separator: "、"))**")
                    )
                    budgets.append(("极端比例卡片：图标不重叠 / 不越界",
                                    (overlapped.isEmpty && outside.isEmpty) ? 0 : nil, 0))

                    let extremeShots = try await CaptureEngine().captureAllDisplays(
                        excludingOwnApplication: false
                    )
                    if let shot = extremeShots.first(where: { $0.displayID == displayID })
                        ?? extremeShots.first
                    {
                        let url = outputDirectory
                            .appendingPathComponent("quickaccess-extreme-\(Int(card.width))x\(Int(card.height)).png")
                        try writePNG(shot.image, to: url)
                        report.append("    截图 -> \(url.path)")
                    }
                    controller.dismiss()
                    try? await Task.sleep(for: .milliseconds(300))
                }

                // 7. 控件自己记的点按延迟（按下 → 反馈 / 动作）。
                report.append("控件内部点按延迟（DEBUG 量测）：")
                report.append(contentsOf: InteractionMetrics.report())
                let feedbackMax = InteractionMetrics.maximum(.feedback)
                let actionMax = InteractionMetrics.maximum(.action)
                // 这两条含系统投递（注入 → 应用处理），给两帧半余量；
                // 历史上双击识别器那种「压后一个双击间隔」是 500ms 量级，这里的阈值足够把它抓出来。
                budgets.append(("按下→反馈（最慢一次，含投递）", feedbackMax, 40))
                budgets.append(("抬起→动作（最慢一次，含投递）", actionMax, 40))

                report.append("延迟预算：")
                var failed = 0
                for budget in budgets {
                    let value = budget.milliseconds
                    let ok = value != nil && value! <= budget.limit
                    if !ok { failed += 1 }
                    report.append(
                        String(
                            format: "    %@ %@ / 预算 %.0f ms  %@",
                            ok ? "✅" : "❌",
                            describe(milliseconds: value),
                            budget.limit,
                            budget.label
                        )
                    )
                }
                report.append("RESULT: \(failed == 0 ? "PASS" : "FAIL（\(failed) 项超预算）")")
                finish(report, code: failed == 0 ? 0 : 1)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    /// 某个动作「可见效果」的说明与预算（毫秒）。
    static func effectLabel(for action: QuickAccessAction) -> String {
        switch action {
        case .save: "落盘"
        case .copy: "写剪贴板"
        case .pin: "钉图窗口出现"
        case .annotate: "编辑器出现"
        case .close: "浮窗消失"
        // 视频卡（录屏收工）那几个走 app 级自检，不在浮窗图标层这条量测里。
        case .play, .reveal, .copyFile, .saveVideo, .trimVideo, .exportGif: action.title
        }
    }

    /// 「动作 → 可见效果」的预算（毫秒）。给的是**上限**，不是期望值：
    /// 落盘要编码 PNG、钉图要建窗、标注要开编辑器，都是几百毫秒内该完的事。
    static func effectLimit(for action: QuickAccessAction) -> Double {
        switch action {
        case .save: 200
        case .copy: 60
        case .pin: 300
        case .annotate: 500
        case .close: 600
        case .play, .reveal, .copyFile, .saveVideo, .trimVideo, .exportGif: 600
        }
    }

    /// 递归找浮窗里的图标层（NSViewRepresentable 会以真实子视图的形式挂进宿主）。
    static func findControlsView(in view: NSView) -> QuickAccessControlsView? {
        if let controls = view as? QuickAccessControlsView { return controls }
        for subview in view.subviews {
            if let found = findControlsView(in: subview) { return found }
        }
        return nil
    }
}

#endif
