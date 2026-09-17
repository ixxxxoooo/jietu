import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 命令行自检入口，只在 Debug 构建里编译。
///
/// 存在的原因：屏幕捕获的失败模式大多发生在「UI 之前」（权限、坐标、缩放），
/// 靠肉眼点界面很难定位。这两个开关让捕获链路可以无人值守地跑通并留下证据。
///
///   Jietu --selftest-capture <输出目录>     冻结全部屏幕 → 落 PNG → 打印报告 → 退出
///   Jietu --selftest-overlay <持续秒数>     冻结全部屏幕 → 弹出遮罩 → 保持 N 秒 → 退出
///   Jietu --selftest-region x,y,w,h         核对 SCK sourceRect 坐标系（直接抓 vs 整屏裁）
///   Jietu --selftest-chrome x,y,w,h         取景框态下「含 / 不含本 App」各抓一张，辨黑屏
///   Jietu --selftest-session x,y,w,h        不弹遮罩，直接跑真实采样会话（自动滚动）
///   Jietu --selftest-frames x,y,w,h [--with-blocker]
///                                           逐拍 dump 帧 + 平均差 / Vision 位移 / 拼接判定
///   Jietu --selftest-scrollprobe x,y,w,h    几种合成滚轮写法哪个能真的推动目标窗口
///   Jietu --selftest-quickaccess <输出目录> 浮窗图标：逐个注入点击，量响应速度（含截图）
///   Jietu --selftest-scroll-cost            滚动长图每帧成本：拼接 / 预览（含老做法对比）
///   Jietu --selftest-record <输出目录>       录屏：真录一段（含暂停），读回成片验时长/尺寸
///   Jietu --selftest-inline-draw <输出目录>   就地标注：验证「框里还能再画框」
///   Jietu --selftest-inline-scroll <输出目录>
///                                           就地工具栏的「滚动截图」：点开手动 / 自动并截图
///   Jietu --selftest-overlay-press <输出目录>
///                                           吸附预览：量「按下 → 窗口描边消失」，拖动中不许回来
enum CaptureSelfTest {
    /// 需要**完整 App 接线**的自检开关。
    ///
    /// 它不归 `handleCommandLineIfNeeded` 管（那个只看 `--selftest` 前缀，认不出的开关一律放行，
    /// 于是启动流程会继续把菜单栏 / 各种 controller 接好），由 `AppDelegate` 接完线之后执行。
    /// 单例守卫也要为它放行：它经常与正式实例同时在场。
    static let appLevelInlineScrollFlag = "--selftest-app-inline-scroll"

    /// 需要完整接线的录屏自检：菜单/遮罩/红框/控制条/落盘，一条链走完。
    static let appLevelRecordingFlag = "--selftest-app-record"

    @MainActor
    static func handleCommandLineIfNeeded() -> Bool {
        let arguments = CommandLine.arguments

        guard let flagIndex = arguments.firstIndex(where: { $0.hasPrefix("--selftest") }) else {
            return false
        }
        // 自检经常被 kill，行缓冲会让日志全部丢失。
        setvbuf(stdout, nil, _IONBF, 0)
        let flag = arguments[flagIndex]
        let value = arguments.count > flagIndex + 1 ? arguments[flagIndex + 1] : nil

        switch flag {
        case "--selftest-capture":
            let directory = URL(
                fileURLWithPath: value ?? NSTemporaryDirectory(),
                isDirectory: true
            )
            runCaptureTest(outputDirectory: directory)
            return true

        case "--selftest-overlay":
            let seconds = Double(value ?? "10") ?? 10
            let directory = arguments.count > flagIndex + 2
                ? URL(fileURLWithPath: arguments[flagIndex + 2], isDirectory: true)
                : URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            runOverlayTest(duration: seconds, outputDirectory: directory)
            return true

        case "--selftest-onboarding":
            runOnboardingTest(duration: Double(value ?? "8") ?? 8)
            return true

        case "--selftest-region":
            // 核对 SCK 的 sourceRect 坐标系：同一块区域「直接抓」与「整屏抓再裁」应当一致。
            runRegionTest(
                spec: value ?? "0,0,400,300",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-chrome":
            // 滚动长图取景框态：遮罩留着 + 本 App 被排除时，区域抓取到底拍到了什么。
            runChromeTest(
                spec: value ?? "400,400,700,500",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-scrollprobe":
            // 合成滚动到底能不能推动目标窗口：把几种事件写法逐个试一遍。
            runScrollProbe(
                spec: value ?? "400,400,700,500",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-frames":
            // 逐步滚动 + 逐帧 dump：看清「滚动到底有没有推动画面 / 拼接为什么拒绝这帧」。
            runFramesTest(
                spec: value ?? "400,400,700,500",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-session":
            // 不弹遮罩，直接跑一遍真实采样会话（自动滚动），复现「没有捕获到滚动内容」。
            runSessionTest(
                spec: value ?? "400,400,700,500",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-scroll-cost":
            // 滚动长图的每帧成本：拼接（Vision / 已知步长）、右侧预览、老做法对比。
            runScrollCostTest()
            return true

        case "--selftest-record":
            // 录屏：真录一段（中间暂停一次），再用 AVFoundation 读回成片验时长 / 尺寸 / 音视频轨。
            runRecordTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case "--selftest-inline-draw":
            // 就地标注：框里还能再画框（矩形/椭圆只认边框，中间是留白）。
            runInlineDrawTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case "--selftest-inline-scroll":
            // 就地编辑工具栏的「滚动截图」：点开手动 / 自动，选完把选区交出去。
            runInlineScrollTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case "--selftest-overlay-press":
            // 吸附预览「按下即收」：鼠标所在窗口的描边，在按下的那一刻就该消失。
            runOverlayPressTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case "--selftest-loupe":
            // 选区放大镜：合成一次「按下 → 拖动 → 停住」，截图看网格 / 读数面板。
            runLoupeTest(
                spec: value ?? "700,600,600,300",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-pin":
            // 钉图：把一张**纯白**图钉在屏幕正中，看两个浮动按钮在白底上还认不认得出来。
            runPinTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case "--selftest-quickaccess":
            // 浮窗图标：真弹一张浮窗、真点每个图标，量「按下 → 反馈 / 动作 / 可见效果」。
            runQuickAccessTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case "--selftest-editor":
            // 标注编辑器：拿一张很小的图开窗，截图检查工具栏有没有被窗口裁掉。
            runEditorTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                ),
                inline: !arguments.contains("--window")
            )
            return true

        default:
            return false
        }
    }

    /// `--selftest-xxx <参数> [输出目录]` 里的输出目录（缺省落临时目录）。
    private static func outputDirectory(_ arguments: [String], after flagIndex: Int) -> URL {
        arguments.count > flagIndex + 2
            ? URL(fileURLWithPath: arguments[flagIndex + 2], isDirectory: true)
            : URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// 标注编辑器窗口：验证「小图 / 原地模式」下工具栏不会被裁。
    /// 放大镜自检：弹出遮罩 → 合成拖拽并在中途停住 → 抓两张（拖动中 / 松手后）。
    ///
    /// 参数 `x,y,w,h` 是拖拽起点与位移（全局 cg 坐标、原点主屏左上）。
    /// 钉图按钮对比度自检：纯白底图上，两个浮动按钮应当仍然是「深色圆盘 + 白图标」。
    private static var retainedQuickAccess: QuickAccessPanelController?
    private static var retainedQuickAccessEditor: AnnotationEditorWindowController?

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
    private static func runQuickAccessTest(outputDirectory: URL) {
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
                var editor: AnnotationEditorWindowController?
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
                controller.onAnnotate = { image in
                    // 先记动作、再开编辑器：建窗是「动作之后」的耗时，不能混进动作延迟里。
                    fire("标注")
                    let editorController = AnnotationEditorWindowController(image: image)
                    editor = editorController
                    retainedQuickAccessEditor = editorController
                    editorController.present()
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
                let editorMs = await effectMs("标注") { editor?.isVisible == true }
                report.append(
                    String(
                        format: "    标注（悬停确认=%@）：按下→动作 %@（墙钟，含 60ms 按住），动作→编辑器出现 %@",
                        annotateHover ? "是" : "否",
                        describe(milliseconds: annotateWall),
                        describe(milliseconds: editorMs)
                    )
                )
                budgets.append(("标注·动作→编辑器出现", editorMs, effectLimit(for: .annotate)))

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
    private static func effectLabel(for action: QuickAccessAction) -> String {
        switch action {
        case .save: "落盘"
        case .copy: "写剪贴板"
        case .pin: "钉图窗口出现"
        case .annotate: "编辑器出现"
        case .close: "浮窗消失"
        // 视频卡（录屏收工）那几个走 app 级自检，不在浮窗图标层这条量测里。
        case .play, .reveal, .copyFile: action.title
        }
    }

    /// 「动作 → 可见效果」的预算（毫秒）。给的是**上限**，不是期望值：
    /// 落盘要编码 PNG、钉图要建窗、标注要开编辑器，都是几百毫秒内该完的事。
    private static func effectLimit(for action: QuickAccessAction) -> Double {
        switch action {
        case .save: 200
        case .copy: 60
        case .pin: 300
        case .annotate: 500
        case .close: 600
        case .play, .reveal, .copyFile: 600
        }
    }

    /// 递归找浮窗里的图标层（NSViewRepresentable 会以真实子视图的形式挂进宿主）。
    private static func findControlsView(in view: NSView) -> QuickAccessControlsView? {
        if let controls = view as? QuickAccessControlsView { return controls }
        for subview in view.subviews {
            if let found = findControlsView(in: subview) { return found }
        }
        return nil
    }

    /// 自检报告里的毫秒格式（两批自检共用；nil = 没等到）。
    static func describe(milliseconds: Double?) -> String {
        guard let milliseconds else { return "**超时**" }
        return String(format: "%.0f ms", milliseconds)
    }

    static func describe(_ values: [CGFloat]) -> String {
        values.map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }

    private static func runPinTest(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            do {
                let screen = NSScreen.main ?? NSScreen.screens[0]
                let visible = screen.visibleFrame
                let scale = max(1, screen.backingScaleFactor)
                let image = try makeWhiteTestImage(width: 520, height: 340)
                PinWindowController.pin(image: image, on: screen)
                try? await Task.sleep(for: .milliseconds(700))

                // 钉图窗口居中、按原始大小显示（和 PinWindowController 的默认摆放一致）。
                let size = CGSize(
                    width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale
                )
                let frame = NSRect(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ).integral
                report.append(
                    "pin frame=\(describe(frame)) (白底图 \(image.width)x\(image.height)px)"
                )

                // 鼠标挪进钉图窗口，浮动按钮才会出现（用户可能同时在动鼠标，多试两次）。
                let inside = CGPoint(
                    x: frame.midX, y: DisplayGeometry.referenceHeight - frame.midY
                )
                let closeCenter = CGPoint(x: frame.maxX - 22, y: frame.maxY - 22)
                var snapshot: DisplaySnapshot?
                for attempt in 1...3 {
                    // 先挪到窗口外面再进来：光标本来就在原地的话不产生移动，触发不了 mouseEntered。
                    postMouse(.mouseMoved, at: CGPoint(x: frame.minX - 60, y: inside.y))
                    try? await Task.sleep(for: .milliseconds(150))
                    postMouse(.mouseMoved, at: inside)
                    try? await Task.sleep(for: .milliseconds(500))
                    let shots = try await CaptureEngine().captureAllDisplays(
                        excludingOwnApplication: false
                    )
                    let shot = shots.first { $0.displayID == NSScreen.main?.jietu_displayID }
                        ?? shots.first
                    snapshot = shot
                    let probe = shot.map { luminance(in: $0, at: closeCenter, size: 6) } ?? 1
                    if probe < 0.9 {
                        break
                    }
                    report.append(
                        String(format: "第 %d 次注入后按钮还是没出来（探到 %.3f），重试", attempt, probe)
                    )
                }

                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )
                guard let snapshot else { throw CaptureError.noDisplays }
                let url = outputDirectory.appendingPathComponent("pin-white.png")
                try writePNG(snapshot.image, to: url)
                report.append("截图 -> \(url.path)")

                // 四个角按钮的中心（各留 8pt 边距；圆盘直径 28，左下角的「翻译」是胶囊）；
                // 各取两块：圆盘边缘（不含图标）与圆心（图标）——前者代表按钮自身的亮度。
                let translateSize = GlassControlButton.preferredSize(
                    diameter: 28, labelText: "翻译"
                )
                let translateCenter = CGPoint(
                    x: frame.minX + 8 + translateSize.width / 2, y: frame.minY + 22
                )
                let buttonCenters = [
                    ("右上关闭", closeCenter),
                    ("右下识别文本", CGPoint(x: frame.maxX - 22, y: frame.minY + 22)),
                    ("左上编辑", CGPoint(x: frame.minX + 22, y: frame.maxY - 22)),
                    ("左下翻译", translateCenter),
                ]
                for (name, center) in buttonCenters {
                    let disc = luminance(in: snapshot, at: center, size: 6)
                    let edge = luminance(
                        in: snapshot, at: CGPoint(x: center.x, y: center.y - 9), size: 6
                    )
                    report.append(
                        String(format: "%@ 圆心=%.3f 圆盘=%.3f（白底=1.000）", name, disc, edge)
                    )
                }

                // 点一下右下角的「识别文本」按钮：开启后应当变成 **macOS 那种蓝底实心圆**。
                // 探针用 AppKit 坐标，注入的鼠标事件得翻成 CG 的 Y 向下坐标。
                let liveTextCenter = CGPoint(x: frame.maxX - 22, y: frame.minY + 22)
                let liveTextClick = CGPoint(
                    x: liveTextCenter.x, y: DisplayGeometry.referenceHeight - liveTextCenter.y
                )
                postMouse(.mouseMoved, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(250))
                postMouse(.leftMouseDown, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(80))
                postMouse(.leftMouseUp, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(900))

                let litShots = try await CaptureEngine().captureAllDisplays(
                    excludingOwnApplication: false
                )
                guard
                    let lit = litShots.first(where: { $0.displayID == snapshot.displayID })
                        ?? litShots.first
                else { throw CaptureError.noDisplays }
                let litURL = outputDirectory.appendingPathComponent("pin-livetext.png")
                try writePNG(lit.image, to: litURL)
                report.append("开启识别文本后截图 -> \(litURL.path)")

                // 按钮圆盘：点亮前后都取同一块，比「蓝偏移」（B−R）——蓝底白图标比绿勾更好认，
                // 未点亮是白玻璃上的黑图标（B−R≈0），点亮后是整块品牌蓝（B−R 明显为正）。
                let offBlue = blueBias(in: snapshot, at: liveTextCenter, size: 6)
                let litBlue = blueBias(in: lit, at: liveTextCenter, size: 6)
                let discBlue = blueBias(in: lit, at: CGPoint(x: frame.maxX - 22, y: frame.minY + 15), size: 4)
                let turnedBlue = litBlue > 0.2 && litBlue - offBlue > 0.2
                report.append(
                    String(format: "按钮中心蓝偏移：点亮前 %.3f → 点亮后 %.3f（圆盘边缘 %.3f）→ %@",
                           offBlue, litBlue, discBlue, turnedBlue ? "已是蓝底实心" : "**没变蓝**")
                )

                // 左下角「翻译」：先关掉识别文本（它会把覆盖层铺满截图，点不到下面的按钮），
                // 再点一次「翻译」，看 macOS 自己的翻译面板有没有弹出来。
                postMouse(.mouseMoved, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(200))
                postMouse(.leftMouseDown, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(80))
                postMouse(.leftMouseUp, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(400))

                // 关闭按钮的响应：从注入「按下」到窗口真的从屏幕上消失。
                // 用户感知的就是这一段（按下动画 + 抬起后关窗）。
                let closeClick = CGPoint(
                    x: closeCenter.x, y: DisplayGeometry.referenceHeight - closeCenter.y
                )
                postMouse(.mouseMoved, at: closeClick)
                try? await Task.sleep(for: .milliseconds(250))
                let pressAt = CFAbsoluteTimeGetCurrent()
                postMouse(.leftMouseDown, at: closeClick)
                try? await Task.sleep(for: .milliseconds(60))  // 普通点击的按住时长
                let releaseAt = CFAbsoluteTimeGetCurrent()
                postMouse(.leftMouseUp, at: closeClick)

                var goneAt: CFAbsoluteTime?
                while CFAbsoluteTimeGetCurrent() - pressAt < 3 {
                    let stillVisible = NSApp.windows.contains { $0 is PinPanel && $0.isVisible }
                    if !stillVisible {
                        goneAt = CFAbsoluteTimeGetCurrent()
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                if let goneAt {
                    report.append(
                        String(
                            format: "关闭按钮：按下→消失 %.0f ms（其中按住 60 ms），抬起→消失 %.0f ms",
                            (goneAt - pressAt) * 1000, (goneAt - releaseAt) * 1000
                        )
                    )
                } else {
                    report.append("关闭按钮：3 秒内窗口**没关掉**")
                }

                // 用一张**有字**的图来验「编辑」与「翻译」（白图识别不出文字）。
                // 上面那张已经关掉了，这张仍钉在屏幕正中。
                let textImage = try makeTextTestImage(width: 520, height: 240)
                PinWindowController.pin(image: textImage, on: screen)
                try? await Task.sleep(for: .milliseconds(700))
                let textCard = CGSize(
                    width: CGFloat(textImage.width) / scale, height: CGFloat(textImage.height) / scale
                )
                let textFrame = NSRect(
                    x: visible.midX - textCard.width / 2,
                    y: visible.midY - textCard.height / 2,
                    width: textCard.width,
                    height: textCard.height
                )

                // 左上角「编辑」：点一下应当把「图 + 钉图位置」交出去，并把自己收掉
                // （回到标注编辑器那条路）。就用手上这张有字的图来验。
                var editHandoff: (imageSize: CGSize, rect: CGRect)?
                PinWindowController.onRequestEdit = { edited, rect in
                    editHandoff = (CGSize(width: edited.width, height: edited.height), rect)
                }
                let editCenter = CGPoint(x: textFrame.minX + 22, y: textFrame.maxY - 22)
                let editClick = CGPoint(
                    x: editCenter.x, y: DisplayGeometry.referenceHeight - editCenter.y
                )
                postMouse(.mouseMoved, at: editClick)
                try? await Task.sleep(for: .milliseconds(250))
                let editPressAt = CFAbsoluteTimeGetCurrent()
                postMouse(.leftMouseDown, at: editClick)
                try? await Task.sleep(for: .milliseconds(80))
                postMouse(.leftMouseUp, at: editClick)
                var editMs: Double?
                while CFAbsoluteTimeGetCurrent() - editPressAt < 2 {
                    if editHandoff != nil {
                        editMs = (CFAbsoluteTimeGetCurrent() - editPressAt) * 1000
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                let pinGone = !NSApp.windows.contains { $0 is PinPanel && $0.isVisible }
                report.append(
                    String(
                        format: "左上角「编辑」→ %@ %@，交出的图=%@，钉图已收掉=%@",
                        editHandoff == nil ? "**没触发**" : "已触发",
                        describe(milliseconds: editMs),
                        editHandoff.map { "\(Int($0.imageSize.width))×\(Int($0.imageSize.height))" } ?? "—",
                        pinGone ? "是" : "**否**"
                    )
                )
                let editOK = editHandoff?.imageSize
                    == CGSize(width: textImage.width, height: textImage.height)
                    && pinGone

                // 左下角「翻译」：再钉一张同样的图，点一次，看 **macOS 自己的翻译面板**弹没弹。
                // （放在最后：面板会浮在图上，挡住后面的点击。）
                PinWindowController.pin(image: textImage, on: screen)
                try? await Task.sleep(for: .milliseconds(700))
                let pinContent = NSApp.windows
                    .compactMap { $0 as? PinPanel }
                    .compactMap { $0.contentView as? PinContentView }
                    .first
                let textTranslateCenter = CGPoint(
                    x: textFrame.minX + 8 + translateSize.width / 2, y: textFrame.minY + 22
                )
                let translateClick = CGPoint(
                    x: textTranslateCenter.x,
                    y: DisplayGeometry.referenceHeight - textTranslateCenter.y
                )
                let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
                postMouse(
                    .mouseMoved,
                    at: CGPoint(x: textTranslateCenter.x, y: textTranslateCenter.y + 200)
                )
                try? await Task.sleep(for: .milliseconds(150))
                let translatePressAt = CFAbsoluteTimeGetCurrent()
                postMouse(.mouseMoved, at: translateClick)
                try? await Task.sleep(for: .milliseconds(250))
                postMouse(.leftMouseDown, at: translateClick)
                try? await Task.sleep(for: .milliseconds(80))
                postMouse(.leftMouseUp, at: translateClick)

                // 先等文字识别（首次可能要装语言模型），再等系统翻译面板。
                var recognizeMs: Double?
                while CFAbsoluteTimeGetCurrent() - translatePressAt < 45 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if pinContent?.recognizedTextForTesting != nil {
                        recognizeMs = (CFAbsoluteTimeGetCurrent() - translatePressAt) * 1000
                        break
                    }
                }
                if recognizeMs == nil {
                    // 可能压根没点中：看看有没有弹「没识别到文字」。
                    report.append("「翻译」：45 秒内没识别出文字（按钮没点中？还是识别卡住了）")
                }
                var translationWindowAppeared = false
                while CFAbsoluteTimeGetCurrent() - translatePressAt < 50 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if NSApp.windows.contains(where: {
                        !windowsBefore.contains(ObjectIdentifier($0)) && $0.isVisible
                    }) {
                        translationWindowAppeared = true
                        break
                    }
                }
                let translationMs = (CFAbsoluteTimeGetCurrent() - translatePressAt) * 1000
                report.append(
                    "「翻译」进度：宿主已挂=\(pinContent?.isTranslationHostAttached ?? false)，"
                        + "识别原文=\(pinContent?.recognizedTextForTesting.map { "\($0.count) 字" } ?? "**还没识别**")"
                        + String(format: "（识别 %.0f ms）", recognizeMs ?? -1)
                        + "，要求弹面板=\(pinContent?.isSystemTranslationPresented ?? false)"
                )
                try? await Task.sleep(for: .milliseconds(700))
                let translateShots = try await CaptureEngine().captureAllDisplays(
                    excludingOwnApplication: false
                )
                if let shot = translateShots.first(where: { $0.displayID == snapshot.displayID })
                    ?? translateShots.first
                {
                    let url = outputDirectory.appendingPathComponent("pin-translate.png")
                    try writePNG(shot.image, to: url)
                    report.append("点「翻译」后截图 -> \(url.path)")
                    // 系统翻译面板浮在钉图上方：那块不该再是白图（亮度会明显掉下来）。
                    let probe = luminance(
                        in: shot,
                        at: CGPoint(x: textFrame.minX + 60, y: textFrame.maxY - 60),
                        size: 8
                    )
                    report.append(
                        String(format: "「翻译」：点击后 %.0f ms，系统翻译面板新窗口=%@，面板区亮度 %.3f",
                               translationMs,
                               translationWindowAppeared ? "已出现" : "**没出现**",
                               probe)
                    )
                } else {
                    report.append("「翻译」：抓不到屏幕，没法看面板")
                }
                let translateOK = pinContent?.recognizedTextForTesting?.isEmpty == false
                    && translationWindowAppeared

                let passed = turnedBlue && editOK && translateOK
                report.append("RESULT: \(passed ? "PASS" : "FAIL")")
                finish(report, code: passed ? 0 : 1)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    /// 指定屏幕点（AppKit 全局坐标）附近一块的像素平均亮度。
    private static func luminance(
        in snapshot: DisplaySnapshot, at center: CGPoint, size: CGFloat
    ) -> Double {
        let scale = snapshot.effectiveScale
        let local = CGPoint(
            x: center.x - snapshot.screenFrameInPoints.minX,
            y: center.y - snapshot.screenFrameInPoints.minY
        )
        let rect = CGRect(
            x: (local.x - size / 2) * scale,
            y: (snapshot.screenFrameInPoints.height - local.y - size / 2) * scale,
            width: size * scale,
            height: size * scale
        )
        return meanLuminance(snapshot.image, pixelRect: rect)
    }

    /// 放大镜自检：弹遮罩 → 自动挑一块**有细节**的屏幕区域 → 合成鼠标移动/拖拽。
    ///
    /// 参数 `x,y` 可指定「候选靶心」的搜索起点（像素、原点左上），省略就全屏找。
    /// 滚动长图的每帧成本自检（用户报过「右侧预览卡顿 / 自动滚动不流畅」）。
    ///
    /// 量三段：
    /// 1. **拼接**：老路每帧跑一次 Vision 配准（20~45ms，就是自动滚动一顿一顿的来源）；
    ///    自动模式把「自己发出去的步长」告诉拼接器，先用它 + 行签名校验，省掉这次配准；
    /// 2. **右侧预览**：老做法是把整张长图交给 SwiftUI 缩放（拷贝量随图长线性涨），
    ///    新做法是定比例小画布、每帧只画新增的几行；
    /// 3. 顺带把「老做法等价开销」也量出来，好在同一个尺度上对比。
    private static func runScrollCostTest() {
        Task { @MainActor in
            var report: [String] = []
            do {
                let pageWidth = 640
                let frameHeight = 200
                let stepPixels = 80
                let frameCount = 60
                let previewSize = ScrollingPreviewPanel.previewPixelSize
                let pageHeight = frameHeight + stepPixels * frameCount
                let page = try makeTallPage(width: pageWidth, height: pageHeight)
                func frame(_ index: Int) -> CGImage {
                    page.cropping(
                        to: CGRect(
                            x: 0, y: index * stepPixels, width: pageWidth, height: frameHeight
                        )
                    ) ?? page
                }

                let session = ScrollStitcher.Session(
                    firstFrame: frame(0),
                    maxFrames: frameCount + 2,
                    maxPixelHeight: 60_000,
                    previewPixelSize: previewSize
                )
                report.append(
                    "选区 \(pageWidth)×\(frameHeight)px，每帧下移 \(stepPixels)px，共 \(frameCount) 帧"
                        + "；预览画布 \(Int(previewSize.width))×\(Int(previewSize.height))px；"
                        + "已知步长 \(stepPixels)px"
                )

                // 老做法的等价开销：每帧把整张长图拷成 CGImage，再整图缩到预览画布。
                let fullBitmap = ScrollStitcher.BitmapData(width: pageWidth, height: pageHeight)
                guard
                    let legacyContext = CGContext(
                        data: nil,
                        width: Int(previewSize.width),
                        height: Int(previewSize.height),
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    )
                else { throw CaptureError.emptyImage(0) }
                legacyContext.interpolationQuality = .low

                var stitchTimes: [Double] = []
                var stitchHintedTimes: [Double] = []
                var previewTimes: [Double] = []
                var legacyTimes: [Double] = []
                var lastPreviewSize = CGSize.zero

                // 同一批帧再跑一轮，这次把「已知步长」告诉拼接器（自动模式就是这么跑的）。
                let hintedSession = ScrollStitcher.Session(
                    firstFrame: frame(0),
                    maxFrames: frameCount + 2,
                    maxPixelHeight: 60_000,
                    previewPixelSize: previewSize
                )
                hintedSession.expectedShiftPixels = stepPixels

                for index in 1...frameCount {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    _ = session.append(frame: frame(index))
                    let t1 = CFAbsoluteTimeGetCurrent()
                    let preview = session.currentPreviewImage()
                    if let preview {
                        lastPreviewSize = CGSize(width: preview.width, height: preview.height)
                    }
                    let t2 = CFAbsoluteTimeGetCurrent()
                    if let full = fullBitmap.makeCGImage(pixelHeight: frameHeight + stepPixels * index) {
                        legacyContext.draw(full, in: CGRect(origin: .zero, size: previewSize))
                    }
                    let t3 = CFAbsoluteTimeGetCurrent()
                    let h0 = CFAbsoluteTimeGetCurrent()
                    _ = hintedSession.append(frame: frame(index))
                    let h1 = CFAbsoluteTimeGetCurrent()
                    stitchTimes.append((t1 - t0) * 1000)
                    previewTimes.append((t2 - t1) * 1000)
                    legacyTimes.append((t3 - t2) * 1000)
                    stitchHintedTimes.append((h1 - h0) * 1000)
                }

                func summary(_ values: [Double]) -> String {
                    let mean = values.reduce(0, +) / Double(values.count)
                    return String(format: "均值 %.2f / 最大 %.2f ms", mean, values.max() ?? 0)
                }
                report.append("    拼接 · Vision 配准（手动 / 无步长线索）：\(summary(stitchTimes))")
                report.append("    拼接 · 已知步长 + 校验（自动模式）：\(summary(stitchHintedTimes))")
                report.append("    新做法取预览（只画新增行）：\(summary(previewTimes))")
                report.append("    老做法等价（整图拷贝 + 整图缩放）：\(summary(legacyTimes))")
                report.append(
                    "    末帧：长图 \(pageWidth)×\(session.currentHeight)px，"
                        + "预览图 \(Int(lastPreviewSize.width))×\(Int(lastPreviewSize.height))px"
                        + "（恒定尺寸，与长图多长无关）"
                )

                let previewMax = previewTimes.max() ?? 0
                let stitchMax = stitchHintedTimes.max() ?? 0
                let ok = previewMax < 4 && lastPreviewSize == previewSize && stitchMax < 12
                if !ok {
                    report.append(
                        "error: 预览每帧超过 4ms，或自动模式的拼接每帧超过 12ms，"
                            + "或预览图尺寸不是画布尺寸"
                    )
                }
                report.append("RESULT: \(ok ? "PASS" : "FAIL")")
                finish(report, code: ok ? 0 : 1)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    /// 自检用的「长页面」：逐行变化的色带 + 黑块。行与行之间得有特征，拼接才判得出位移。
    private static func makeTallPage(width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw CaptureError.emptyImage(0) }

        context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for y in stride(from: 0, to: height, by: 16) {
            let t = CGFloat(y) / CGFloat(max(1, height))
            context.setFillColor(
                CGColor(red: 0.2 + 0.6 * t, green: 0.3, blue: 0.8 - 0.5 * t, alpha: 1)
            )
            context.fill(CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: 5))
        }
        for index in 0..<(height / 40) {
            let y = CGFloat(index) * 40 + 10
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(
                CGRect(
                    x: CGFloat((index * 37) % max(1, width - 60)), y: y, width: 40, height: 12
                )
            )
        }
        guard let image = context.makeImage() else { throw CaptureError.emptyImage(0) }
        return image
    }

    /// 录屏自检：同一段画面**录两次**（一次中间暂停、一次不暂停），再用 AVFoundation 读回成片比时长。
    ///
    /// 为什么要比而不是绝对值：SCK 首帧来得有早有晚（静止画面只在变化时出帧），
    /// 单看一次录制的时长会把「首帧晚到」算进去。两次录制的环境一样，
    /// 差值就是「暂停那一段有没有被抽掉」+「暂停后有没有继续录」：
    /// - 差值 ≈ 第二段的有效时长（1.4s）→ 正确；
    /// - 差值 ≈ 暂停时长 + 第二段（2.9s）→ 暂停被算进成片了（bug）。
    private static func runRecordTest(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            var budgets: [(label: String, milliseconds: Double?, limit: Double)] = []
            do {
                guard let screen = NSScreen.main, let displayID = screen.jietu_displayID
                else { throw CaptureError.noDisplays }
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                // 显示器 local 坐标（原点左上）：屏幕中上部一块，避开菜单栏。
                let region = CGRect(x: 240, y: 200, width: 560, height: 360)
                let scale = screen.backingScaleFactor
                report.append(
                    "区域 \(describe(region)) 缩放 \(scale)x → 期望像素 "
                        + "\(Int(region.width * scale))×\(Int(region.height * scale))"
                )

                let engineOptions = RecordingEngine.Options(fps: 30, capturesSystemAudio: false)

                /// 录制期间持续在选区里挪光标：SCK 只在画面有变化时出帧。
                @MainActor func wiggle(seconds: Double) async {
                    let deadline = CFAbsoluteTimeGetCurrent() + seconds
                    var index = 0
                    while CFAbsoluteTimeGetCurrent() < deadline {
                        let t = CGFloat(index) * 0.35
                        postMouse(
                            .mouseMoved,
                            at: CGPoint(
                                x: region.midX + cos(t) * region.width * 0.32,
                                y: region.midY + sin(t) * region.height * 0.32
                            )
                        )
                        index += 1
                        try? await Task.sleep(for: .milliseconds(70))
                    }
                }

                /// 录一段（`pauseSeconds > 0` 时在中间暂停一下），返回成片时长。
                @MainActor func record(phase: Double, pauseSeconds: Double, name: String) async -> (
                    duration: Double, url: URL?, error: Error?
                ) {
                    let engine = RecordingEngine()
                    var finished: URL?
                    var failure: Error?
                    var ticks = 0
                    engine.onTick = { _ in ticks += 1 }
                    engine.onFinish = { finished = $0 }
                    engine.onFail = { failure = $0 }
                    do {
                        try await engine.start(
                            displayID: displayID,
                            regionInPoints: region,
                            options: engineOptions,
                            excludingWindowNumbers: []
                        )
                    } catch {
                        return (-1, nil, error)
                    }
                    await wiggle(seconds: phase)
                    if pauseSeconds > 0 {
                        engine.pause()
                        try? await Task.sleep(for: .milliseconds(Int(pauseSeconds * 1000)))
                        engine.resume()
                        await wiggle(seconds: phase)
                    }
                    await engine.stop()
                    report.append("  \(name)：tick \(ticks) 次")
                    guard let url = finished else { return (-1, nil, failure) }
                    let saved = outputDirectory.appendingPathComponent("\(name).mp4")
                    try? FileManager.default.removeItem(at: saved)
                    try? FileManager.default.moveItem(at: url, to: saved)
                    let asset = AVURLAsset(url: saved)
                    let duration = (try? await asset.load(.duration)).map {
                        CMTimeGetSeconds($0)
                    } ?? -1
                    return (duration, saved, failure)
                }

                let phase = 1.4
                let pause = 1.5
                let plain = await record(phase: phase, pauseSeconds: 0, name: "record-plain")
                let paused = await record(phase: phase, pauseSeconds: pause, name: "record-paused")
                report.append(String(format: "  不暂停：%.2fs（期望 ~%.1fs）", plain.duration, phase))
                report.append(
                    String(
                        format: "  中间暂停 %.1fs：%.2fs（期望 ~%.1fs，不是 ~%.1fs）",
                        pause, paused.duration, phase * 2, phase * 2 + pause
                    )
                )

                if let error = plain.error ?? paused.error {
                    report.append("error: 录制失败 —— \(error.localizedDescription)")
                    report.append("RESULT: FAIL")
                    finish(report, code: 1)
                    return
                }
                guard let url = paused.url else {
                    report.append("error: 没有拿到成片")
                    report.append("RESULT: FAIL")
                    finish(report, code: 1)
                    return
                }

                // 成片规格：像素 = 区域 × 缩放；没开系统音频时只有一条视频轨。
                let asset = AVURLAsset(url: url)
                let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                let naturalSize = (try? await videoTracks.first?.load(.naturalSize)) ?? .zero
                let expectedSize = CGSize(width: region.width * scale, height: region.height * scale)
                let sizeOK = abs((naturalSize.width) - expectedSize.width) < 3
                    && abs((naturalSize.height) - expectedSize.height) < 3
                report.append(
                    "成片 -> \(url.path)；像素 \(Int(naturalSize.width))×\(Int(naturalSize.height))、"
                        + "视频轨 \(videoTracks.count) 条 / 音频轨 \(audioTracks.count) 条"
                )

                let delta = paused.duration - plain.duration
                let plainOK = plain.duration > 0.8 && plain.duration < phase + 0.9
                let deltaOK = delta > 0.6 && delta < phase + 0.8
                budgets.append(("不暂停那次的时长 ≈ 有效时长", plainOK ? 0 : nil, 0))
                budgets.append(
                    ("暂停后被继续录制、且暂停没算进成片（Δ=\(String(format: "%.2f", delta))s）",
                     deltaOK ? 0 : nil, 0)
                )
                budgets.append(("像素尺寸 = 区域 × 缩放", sizeOK ? 0 : nil, 0))
                budgets.append(("一条视频轨、没声音时没音频轨", videoTracks.count == 1 && audioTracks.isEmpty ? 0 : nil, 0))

                report.append("延迟预算：")
                var failed = 0
                for budget in budgets {
                    let ok = budget.milliseconds != nil && budget.milliseconds! <= budget.limit
                    if !ok { failed += 1 }
                    report.append("    \(ok ? "✅" : "❌") \(budget.label)")
                }
                report.append("RESULT: \(failed == 0 ? "PASS" : "FAIL（\(failed) 项未达成）")")
                finish(report, code: failed == 0 ? 0 : 1)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    /// 就地标注「框里还能再画框」自检。
    ///
    /// 用户报过：画完一个矩形（或椭圆），再想在它**里面**画一个，一按就变成
    /// 「选中并移动外面那个框」，中间根本画不上东西。
    /// 根因：命中判定按**整块矩形**算，而渲染只画了边框（`context.stroke`）。
    ///
    /// 这条自检真画两个框（第二个画在第一个里面），再采样内框的上边：
    /// 有标注色 = 框画出来了；没颜色 = 又被外面那个框吃掉了。
    private static func runInlineDrawTest(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            do {
                let engine = CaptureEngine()
                let snapshots = try await engine.captureAllDisplays()
                guard let snapshot = snapshots.first else { throw CaptureError.noDisplays }
                let displayID = snapshot.displayID
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                let coordinator = OverlayCoordinator()
                retainedCoordinator = coordinator
                coordinator.purpose = .screenshot
                // 就地模式：拖完选区松手就进标注，工具栏浮在选区下方。
                coordinator.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: true
                )
                try? await Task.sleep(for: .milliseconds(700))

                /// 注入一次拖拽（cg 坐标）。
                @MainActor func drag(from start: CGPoint, to end: CGPoint) async {
                    postMouse(.mouseMoved, at: CGPoint(x: start.x - 40, y: start.y - 40))
                    try? await Task.sleep(for: .milliseconds(120))
                    postMouse(.mouseMoved, at: start)
                    try? await Task.sleep(for: .milliseconds(100))
                    postMouse(.leftMouseDown, at: start)
                    for step in 1...6 {
                        let t = CGFloat(step) / 6
                        postMouse(
                            .leftMouseDragged,
                            at: CGPoint(
                                x: start.x + (end.x - start.x) * t,
                                y: start.y + (end.y - start.y) * t
                            )
                        )
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    postMouse(.leftMouseUp, at: end)
                    try? await Task.sleep(for: .milliseconds(250))
                }

                // 先拖出选区（松手即进就地标注）。
                await drag(from: CGPoint(x: 420, y: 300), to: CGPoint(x: 1240, y: 900))
                report.append(
                    "选区=" + (coordinator.debugSelections
                        .first { $0.displayID == displayID }?.localRect
                        .map(describe) ?? "无")
                )

                // 外框 + **框内**的内框。
                let outerStart = CGPoint(x: 520, y: 420)
                let outerEnd = CGPoint(x: 1000, y: 760)
                let innerStart = CGPoint(x: 640, y: 520)
                let innerEnd = CGPoint(x: 880, y: 680)
                await drag(from: outerStart, to: outerEnd)
                await drag(from: innerStart, to: innerEnd)

                let shots = try await engine.captureAllDisplays(excludingOwnApplication: false)
                guard let shot = shots.first(where: { $0.displayID == displayID }) ?? shots.first
                else { throw CaptureError.noDisplays }
                let url = outputDirectory.appendingPathComponent("inline-two-rects.png")
                try writePNG(shot.image, to: url)
                report.append("画了内外两个框 -> \(url.path)")

                // 内框上边应当描着标注色（默认红）。采样点避开边的**中点**：
                // 画完的框是选中态，边中点正好压着一个绿色缩放手柄。
                let fractions: [CGFloat] = [0.2, 0.3, 0.7, 0.8]
                var samples: [(CGFloat, (red: Double, green: Double, blue: Double))] = []
                for fraction in fractions {
                    let point = CGPoint(
                        x: innerStart.x + (innerEnd.x - innerStart.x) * fraction,
                        y: innerStart.y
                    )
                    let rgb = meanRGB(
                        shot.image,
                        pixelRect: pixelRect(
                            in: shot,
                            at: CGPoint(x: point.x, y: DisplayGeometry.referenceHeight - point.y),
                            size: 4
                        )
                    )
                    samples.append((fraction, rgb))
                }
                // 至少两个采样点是明显的红（边框线宽 7px，采样框 4pt 落在线上）。
                let reds = samples.filter { $0.1.red > $0.1.green + 0.15 && $0.1.red > $0.1.blue + 0.15 }
                let isStroke = reds.count >= 2
                report.append(
                    "内框上边采样：" + samples.map {
                        String(format: "%.1f→(%.2f,%.2f,%.2f)", $0.0, $0.1.red, $0.1.green, $0.1.blue)
                    }.joined(separator: " ")
                )
                report.append("→ \(isStroke ? "有标注色：框里画上了" : "**没有标注色：又被外框吃掉了**")")

                coordinator.cancel()
                report.append("RESULT: \(isStroke ? "PASS" : "FAIL")")
                finish(report, code: isStroke ? 0 : 1)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    /// 就地编辑工具栏的「滚动截图」自检。
    ///
    /// 验两件事：
    /// 1. **选项条长什么样**（截图给人看）：点一下工具栏的「滚动截图」，
    ///    下方浮出「谁来滚 → 手动滚动 / 自动滚动」；
    /// 2. 选完之后**把「模式 + 当前选区」交到了外面**（真会话要建控制条 / 实时预览、
    ///    还要把遮罩换成取景框，那是 AppDelegate 那一层；自检进程里没有它）。
    private static func runInlineScrollTest(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            var budgets: [(label: String, milliseconds: Double?, limit: Double)] = []
            do {
                let engine = CaptureEngine()
                let snapshots = try await engine.captureAllDisplays()
                guard let snapshot = snapshots.first else { throw CaptureError.noDisplays }
                let screen = NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID }
                    ?? NSScreen.main ?? NSScreen.screens[0]
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                @MainActor func waitUntil(
                    _ since: CFAbsoluteTime, timeout: TimeInterval = 1.5,
                    until condition: () -> Bool
                ) async -> Double? {
                    while CFAbsoluteTimeGetCurrent() - since < timeout {
                        if condition() { return (CFAbsoluteTimeGetCurrent() - since) * 1000 }
                        try? await Task.sleep(for: .milliseconds(4))
                    }
                    return nil
                }

                let coordinator = OverlayCoordinator()
                retainedCoordinator = coordinator
                coordinator.purpose = .screenshot
                var handoff: (mode: ScrollingCaptureSession.Mode, rect: CGRect)?
                coordinator.onScrollCapture = { _, mode, rect in handoff = (mode, rect) }
                // 就地模式：松手即进标注，工具栏浮到选区下方。
                coordinator.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: true
                )
                try? await Task.sleep(for: .milliseconds(700))

                // 拖一块选区。
                let start = CGPoint(x: 320, y: 260)
                let end = CGPoint(x: 900, y: 700)
                postMouse(.mouseMoved, at: CGPoint(x: 200, y: 160))
                try? await Task.sleep(for: .milliseconds(150))
                postMouse(.mouseMoved, at: start)
                try? await Task.sleep(for: .milliseconds(120))
                postMouse(.leftMouseDown, at: start)
                for step in 1...6 {
                    let t = CGFloat(step) / 6
                    postMouse(
                        .leftMouseDragged,
                        at: CGPoint(
                            x: start.x + (end.x - start.x) * t,
                            y: start.y + (end.y - start.y) * t
                        )
                    )
                    try? await Task.sleep(for: .milliseconds(40))
                }
                postMouse(.leftMouseUp, at: end)
                try? await Task.sleep(for: .milliseconds(600))

                guard
                    let selection = coordinator.debugSelections
                        .first(where: { $0.displayID == snapshot.displayID })?.localRect
                else {
                    report.append("error: 就地模式没有形成选区 / 没有工具栏")
                    report.append("RESULT: FAIL")
                    finish(report, code: 1)
                    return
                }
                report.append("就地选区=\(describe(selection))")

                // 1. 点开「滚动截图」：截图看选项条。
                guard coordinator.debugOpenScrollOptions(displayID: snapshot.displayID) else {
                    report.append("error: 工具栏没出现（就地标注没进去）")
                    report.append("RESULT: FAIL")
                    finish(report, code: 1)
                    return
                }
                try? await Task.sleep(for: .milliseconds(350))
                let shots = try await engine.captureAllDisplays(excludingOwnApplication: false)
                if let shot = shots.first(where: { $0.displayID == snapshot.displayID })
                    ?? shots.first
                {
                    let url = outputDirectory.appendingPathComponent("inline-scroll-options.png")
                    try writePNG(shot.image, to: url)
                    report.append("选项条截图 -> \(url.path)")
                }

                // 2. 选「手动滚动」：模式 + 选区要交出去。
                let firedAt = CFAbsoluteTimeGetCurrent()
                let triggered = coordinator.debugTriggerScrollCapture(
                    .manual, displayID: snapshot.displayID
                )
                let handoffMs = await waitUntil(firedAt, timeout: 1) { handoff != nil }
                let rectMatches = handoff.map {
                    abs($0.rect.minX - selection.minX) < 2 && abs($0.rect.minY - selection.minY) < 2
                        && abs($0.rect.width - selection.width) < 2
                        && abs($0.rect.height - selection.height) < 2
                } ?? false
                report.append(
                    String(
                        format: "点「滚动截图 → 手动滚动」→ %@，模式=%@，选区=%@ %@",
                        triggered ? "已触发" : "**没触发**",
                        handoff.map { $0.mode == .manual ? "手动" : "自动" } ?? "—",
                        handoff.map { describe($0.rect) } ?? "—",
                        rectMatches ? "（与选区一致）" : "**（与选区不一致）**"
                    )
                )
                report.append(
                    "（提示：屏幕坐标注入点在主屏上；此自检只验「模式 + 选区交出去」，"
                        + "真会话由 AppDelegate 起）"
                )

                budgets.append(("按下→交出手续", handoffMs, 100))
                budgets.append(("交出的选区与选区一致", rectMatches ? 0 : nil, 0))
                _ = screen

                coordinator.cancel()
                report.append("延迟预算：")
                var failed = 0
                for budget in budgets {
                    let ok = budget.milliseconds != nil && budget.milliseconds! <= budget.limit
                    if !ok { failed += 1 }
                    report.append(
                        String(
                            format: "    %@ %@ / 预算 %.0f ms  %@",
                            ok ? "✅" : "❌",
                            describe(milliseconds: budget.milliseconds),
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

    /// 吸附预览「按下即收」自检。
    ///
    /// 用户报的现象：鼠标停在一个窗口上，那圈绿色吸附描边好好的；**一按下准备框选**，
    /// 描边却还赖在窗口上不动（一直拖到选区成型才不见）。视觉焦点应该当场跟到
    /// 鼠标开始操作的地方去。
    ///
    /// 这条自检把四段都量一遍：悬停出现 → 按下消失（毫秒）→ 拖动全程不回来 → 松手后该回来就回来。
    private static func runOverlayPressTest(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            var budgets: [(label: String, milliseconds: Double?, limit: Double)] = []
            do {
                let engine = CaptureEngine()
                let snapshots = try await engine.captureAllDisplays()
                guard let snapshot = snapshots.first else { throw CaptureError.noDisplays }
                let screen = NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID }
                    ?? NSScreen.main ?? NSScreen.screens[0]
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                let coordinator = OverlayCoordinator()
                retainedCoordinator = coordinator
                coordinator.purpose = .screenshot
                coordinator.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: false
                )
                try? await Task.sleep(for: .milliseconds(700))

                @MainActor func waitUntil(
                    _ since: CFAbsoluteTime, timeout: TimeInterval = 1.5,
                    until condition: () -> Bool
                ) async -> Double? {
                    while CFAbsoluteTimeGetCurrent() - since < timeout {
                        if condition() { return (CFAbsoluteTimeGetCurrent() - since) * 1000 }
                        try? await Task.sleep(for: .milliseconds(4))
                    }
                    return nil
                }

                @MainActor func highlightVisible() -> Bool? {
                    coordinator.debugWindowHighlightVisible(displayID: snapshot.displayID)
                }

                /// 找一个「鼠标放上去必定命中某个窗口」的点：取各窗口中心，
                /// 用 App 自己那套命中测试确认它确实是该窗口的最前面。
                @MainActor func probePoint() -> (point: CGPoint, window: WindowInfo)? {
                    for window in windows {
                        let cg = CGPoint(
                            x: window.frameInCGPoints.midX, y: window.frameInCGPoints.midY
                        )
                        let appKit = CGPoint(x: cg.x, y: DisplayGeometry.referenceHeight - cg.y)
                        guard screen.frame.contains(appKit) else { continue }
                        guard WindowHitTester.frontmost(atCGPoint: cg, in: windows)?.windowID
                            == window.windowID
                        else { continue }
                        return (appKit, window)
                    }
                    return nil
                }

                guard let probe = probePoint() else {
                    report.append("error: 屏幕上找不到可命中的窗口，无法测吸附预览")
                    report.append("RESULT: FAIL")
                    finish(report, code: 1)
                    return
                }
                let start = CGPoint(
                    x: probe.point.x, y: DisplayGeometry.referenceHeight - probe.point.y
                )
                report.append(
                    "探针窗口=\(probe.window.displayName) \(describe(probe.window.frameInCGPoints))"
                        + " 注入点=(\(Int(start.x)),\(Int(start.y)))"
                )

                // 1. 悬停（前置条件）：探针窗口的描边必须已经画着——
                //    否则「按下后隐藏」是白拿的，这条自检等于没测。
                postMouse(.mouseMoved, at: CGPoint(x: start.x - 300, y: start.y - 200))
                try? await Task.sleep(for: .milliseconds(150))
                let hoverAt = CFAbsoluteTimeGetCurrent()
                postMouse(.mouseMoved, at: start)
                let appearMs = await waitUntil(hoverAt, timeout: 1.0) { highlightVisible() == true }
                guard appearMs != nil else {
                    report.append("error: 探针点没有出现吸附描边，测不了「按下即收」")
                    report.append("RESULT: FAIL")
                    finish(report, code: 1)
                    return
                }
                report.append(
                    String(format: "悬停 → 描边出现 %@（前置条件成立）", describe(milliseconds: appearMs))
                )

                // 2. 按下：描边**当场**消失。
                let pressAt = CFAbsoluteTimeGetCurrent()
                postMouse(.leftMouseDown, at: start)
                let goneMs = await waitUntil(pressAt, timeout: 0.6) { highlightVisible() == false }
                report.append(
                    String(format: "按下 → 描边消失 %@（按住不放）", describe(milliseconds: goneMs))
                )
                budgets.append(("按下 → 描边消失", goneMs, 60))

                // 3. 拖动全程都不许回来；顺便截一张拖动中的图给人看。
                var stillHidden = true
                var dragReport: [String] = []
                for step in 1...4 {
                    let point = CGPoint(
                        x: start.x + CGFloat(step) * 18, y: start.y + CGFloat(step) * 12
                    )
                    postMouse(.leftMouseDragged, at: point)
                    try? await Task.sleep(for: .milliseconds(60))
                    let visible = highlightVisible() ?? true
                    if visible { stillHidden = false }
                    dragReport.append("第 \(step) 步 \(visible ? "**又出现了**" : "仍收起")")
                }
                let draggingShots = try await engine.captureAllDisplays(
                    excludingOwnApplication: false
                )
                if let shot = draggingShots.first(where: { $0.displayID == snapshot.displayID })
                    ?? draggingShots.first
                {
                    let url = outputDirectory.appendingPathComponent("overlay-press-dragging.png")
                    try writePNG(shot.image, to: url)
                    report.append("拖动中截图 -> \(url.path)")
                }
                report.append("拖动中描边状态：" + dragReport.joined(separator: "，"))
                budgets.append(("拖动中不再出现描边", stillHidden ? 0 : nil, 0))

                // 4. 松手 → 选区成型（描边不该回来）；再按一次拖一点点松手（选区被丢弃）→ 描边该回来。
                postMouse(.leftMouseUp, at: CGPoint(x: start.x + 72, y: start.y + 48))
                try? await Task.sleep(for: .milliseconds(250))
                let settledRect = coordinator.debugSelections
                    .first { $0.displayID == snapshot.displayID }?.localRect
                let settledVisible = (highlightVisible() ?? false) ? "还在（不应出现）" : "收起"
                report.append(
                    "松手 → 选区=\(settledRect.map(describe) ?? "无")，描边=\(settledVisible)"
                )

                // 远离刚成型的选区（贴上去会按到它的控制点，变成「调整选区」而不是「框新的」）。
                let away = CGPoint(x: start.x - 300, y: start.y - 200)
                postMouse(.leftMouseDown, at: away)
                try? await Task.sleep(for: .milliseconds(40))
                // 拖过 3pt 阈值但不到最小选区（6pt）：松手时选区被丢弃，回到「还没选区」。
                postMouse(.leftMouseDragged, at: CGPoint(x: away.x + 4, y: away.y + 1))
                try? await Task.sleep(for: .milliseconds(40))
                postMouse(.leftMouseUp, at: CGPoint(x: away.x + 4, y: away.y + 1))
                let backAt = CFAbsoluteTimeGetCurrent()
                let backMs = await waitUntil(backAt, timeout: 1.5) { highlightVisible() == true }
                let clearedRect = coordinator.debugSelections
                    .first { $0.displayID == snapshot.displayID }?.localRect
                report.append(
                    String(
                        format: "松手（没形成选区，选区=%@）→ 描边回来 %@",
                        clearedRect.map(describe) ?? "无",
                        describe(milliseconds: backMs)
                    )
                )
                budgets.append(("取消框选后描边回来", backMs, 200))

                // 5. 按下不拖动 = 截图那个窗口：按下路径上最容易被「收预览」改坏的就是它，
                //    必须确认还在（收的是画面，`hoveredWindow` 状态不能被连带动到）。
                var capturedWindow: WindowInfo?
                coordinator.onFinish = { outcome in
                    if case .windowCaptured(let window, _) = outcome { capturedWindow = window }
                }
                // 光标先真的挪过去（hoveredWindow 要落在探针窗口上），
                // 再用**合成事件**直接送进遮罩点击——注入管线对「同一位置的按下 → 抬起」
                // 很挑（实测抬起要等下一次移动才被投递），这里验的是按下路径本身。
                postMouse(.mouseMoved, at: probe.point)
                try? await Task.sleep(for: .milliseconds(250))
                // 注意：本节的计时一律用 `CFAbsoluteTimeGetCurrent()`（与上面的 `waitUntil` 同源）。
                // 它和 `CACurrentMediaTime()` 是两套基准（实测差 8 亿秒），混用会算出「几十年前」。
                let clickPressAt = CFAbsoluteTimeGetCurrent()
                let sent = coordinator.debugClick(
                    atAppKitPoint: probe.point, displayID: snapshot.displayID
                )
                let capturedMs = await waitUntil(clickPressAt, timeout: 1) { capturedWindow != nil }
                if !sent {
                    report.append("error: 没找到遮罩，合成点击没送出去")
                }
                report.append(
                    String(
                        format: "单击窗口（不拖动）→ %@ %@",
                        capturedWindow.map { "截取「\($0.displayName)」" } ?? "**没截到窗口**",
                        describe(milliseconds: capturedMs)
                    )
                )
                budgets.append(("单击窗口 → 截取", sent ? capturedMs : nil, 100))

                coordinator.cancel()
                report.append("延迟预算：")
                var failed = 0
                for budget in budgets {
                    let ok = budget.milliseconds != nil && budget.milliseconds! <= budget.limit
                    if !ok { failed += 1 }
                    report.append(
                        String(
                            format: "    %@ %@ / 预算 %.0f ms  %@",
                            ok ? "✅" : "❌",
                            describe(milliseconds: budget.milliseconds),
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

    private static func runLoupeTest(spec: String, outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            do {
                let engine = CaptureEngine()
                let snapshots = try await engine.captureAllDisplays()
                guard let snapshot = snapshots.first else { throw CaptureError.noDisplays }
                let screen = NSScreen.screens.first { $0.jietu_displayID == snapshot.displayID }
                    ?? NSScreen.main ?? NSScreen.screens[0]
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())

                // 靶心：挑一块「细节最多」的地方（相邻像素差异大），采样偏一格就会露馅。
                let hotspot = Self.texturedPixel(in: snapshot.image)
                let local = CGPoint(
                    x: (CGFloat(hotspot.x) + 0.5) / snapshot.effectiveScale,
                    y: snapshot.screenFrameInPoints.height
                        - (CGFloat(hotspot.y) + 0.5) / snapshot.effectiveScale
                )
                let appKit = DisplayGeometry.appKitPoint(fromLocal: local, screen: screen)
                let start = CGPoint(
                    x: appKit.x, y: DisplayGeometry.referenceHeight - appKit.y
                )
                report.append(
                    "靶心像素=(\(hotspot.x),\(hotspot.y)) 注入点=(\(Int(start.x)),\(Int(start.y)))"
                        + " display=\(snapshot.displayID)"
                )

                let coordinator = OverlayCoordinator()
                retainedCoordinator = coordinator
                coordinator.purpose = .screenshot
                coordinator.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: false
                )
                try? await Task.sleep(for: .milliseconds(600))
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                // 先出画再进来：光标本来就在原地的话不产生移动，触发不了跟踪事件。
                postMouse(.mouseMoved, at: CGPoint(x: start.x - 300, y: start.y - 200))
                try? await Task.sleep(for: .milliseconds(150))
                postMouse(.mouseMoved, at: start)

                // 「跟手」检查：放大镜刚出现时就该在光标旁边，不能有从图层原点滑过来的动画。
                var elapsed = 0
                for sampleAt in [40, 140, 360] {
                    try? await Task.sleep(for: .milliseconds(sampleAt - elapsed))
                    elapsed = sampleAt
                    let visibleLoupe = coordinator.debugSelections.compactMap { entry in
                        coordinator.debugLoupePresentation(displayID: entry.displayID)
                    }.first { !$0.isHidden }
                    if let probe = visibleLoupe {
                        let drift = probe.presentation.map {
                            String(
                                format: " 呈现偏差=(%.0f,%.0f)",
                                $0.origin.x - probe.model.origin.x,
                                $0.origin.y - probe.model.origin.y
                            )
                        } ?? " 呈现=与模型一致（无动画）"
                        report.append("t+\(sampleAt)ms 模型=\(describe(probe.model))\(drift)")
                    } else {
                        report.append("t+\(sampleAt)ms 放大镜还没出来")
                    }
                }

                // 「取的是不是鼠标那一格像素」检查：放大镜里每格的颜色，必须等于
                // 冻结图（= 本 App 被排除时看到的那块）同一坐标的像素。
                report.append(
                    contentsOf: await verifyLoupeSampling(
                        coordinator: coordinator, frozen: snapshots, engine: engine
                    )
                )

                try? await Task.sleep(for: .milliseconds(120))
                postMouse(.leftMouseDown, at: start)
                let delta = CGSize(width: 400, height: 300)
                let end = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
                for step in 1...8 {
                    let t = CGFloat(step) / 8
                    postMouse(
                        .leftMouseDragged,
                        at: CGPoint(
                            x: start.x + delta.width * t, y: start.y + delta.height * t
                        )
                    )
                    try? await Task.sleep(for: .milliseconds(40))
                }
                try? await Task.sleep(for: .milliseconds(500))

                let dragging = try await engine.captureAllDisplays(
                    excludingOwnApplication: false
                )
                for (index, shot) in dragging.enumerated() {
                    let url = outputDirectory
                        .appendingPathComponent("loupe-dragging-\(index).png")
                    try writePNG(shot.image, to: url)
                    report.append("拖动中 display \(shot.displayID) -> \(url.lastPathComponent)")
                }

                postMouse(.leftMouseUp, at: end)
                try? await Task.sleep(for: .milliseconds(500))
                let released = try await engine.captureAllDisplays(
                    excludingOwnApplication: false
                )
                for (index, shot) in released.enumerated() {
                    let url = outputDirectory
                        .appendingPathComponent("loupe-released-\(index).png")
                    try writePNG(shot.image, to: url)
                    report.append("松手后 display \(shot.displayID) -> \(url.lastPathComponent)")
                }

                coordinator.cancel()
                report.append("RESULT: PASS")
                finish(report, code: 0)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    /// 在图像里找「细节最多」的 13×13 窗口（相邻像素差异之和最大），返回其左上角像素。
    /// 在冻结图里找「细节最多」的一块 13×13（相邻像素差异之和最大），返回它的左上角像素。
    ///
    /// 用 `BitmapData` 一次性把图读进内存再扫，逐点走 `PixelSampler` 会慢到不可用。
    private static func texturedPixel(in image: CGImage) -> CGPoint {
        guard let bitmap = ScrollStitcher.BitmapData(image: image) else {
            return CGPoint(x: image.width / 2, y: image.height / 2)
        }
        let step = max(8, bitmap.width / 320)
        var best = CGPoint(x: bitmap.width / 2, y: bitmap.height / 2)
        var bestScore = -1
        var y = 40
        while y + 13 < bitmap.height - 40 {
            var x = 40
            while x + 13 < bitmap.width - 40 {
                var score = 0
                for dy in 0..<12 {
                    for dx in 0..<12 {
                        let a = bitmap.pixel(x: x + dx, y: y + dy)
                        let down = bitmap.pixel(x: x + dx, y: y + dy + 1)
                        let right = bitmap.pixel(x: x + dx + 1, y: y + dy)
                        for (lhs, rhs) in [(a, down), (a, right)] {
                            score += abs(Int(lhs.r) - Int(rhs.r))
                                + abs(Int(lhs.g) - Int(rhs.g))
                                + abs(Int(lhs.b) - Int(rhs.b))
                        }
                    }
                }
                if score > bestScore {
                    bestScore = score
                    best = CGPoint(x: x, y: y)
                }
                x += step
            }
            y += step
        }
        return best
    }

    /// 放大镜取像素的正确性：把放大镜里每一格的颜色，与冻结图上「同一坐标」的像素对齐比较。
    ///
    /// 只要采样窗口 / 格子映射有任何偏移或上下翻转，这里就会列出一堆对不上的格子。
    ///
    /// 用户可能同时在动鼠标，所以「读状态 → 抓图 → 再读状态」两遍状态一致才算数，否则重试。
    private static func verifyLoupeSampling(
        coordinator: OverlayCoordinator,
        frozen: [DisplaySnapshot],
        engine: CaptureEngine
    ) async -> [String] {
        var lines: [String] = []
        for attempt in 1...3 {
            guard
                let before = activeLoupeState(coordinator),
                let frozenShot = frozen.first(where: { $0.displayID == before.displayID })
            else { return ["放大镜不可见：跳过「取像素」检查"] }

            guard
                let ui = try? await engine.captureAllDisplays(excludingOwnApplication: false)
                    .first(where: { $0.displayID == before.displayID })
            else { return ["抓不到遮罩图：跳过「取像素」检查"] }

            let state = before.state
            guard let after = activeLoupeState(coordinator), after.state.cursorPixel == state.cursorPixel
            else {
                lines.append("第 \(attempt) 次：抓到一半光标动了，重来")
                continue
            }

            lines.append(
                "放大镜 frame=\(describe(state.frame))"
                    + " 采样窗口左上=(\(Int(state.sourceOrigin.x)),\(Int(state.sourceOrigin.y)))"
                    + " 光标像素=(\(Int(state.cursorPixel.x)),\(Int(state.cursorPixel.y)))"
                    + " 光标格=(\(Int(state.cell.x)),\(Int(state.cell.y)))"
                    + " 色=\(state.hex ?? "-")"
            )

            // 用系统光标位置（与 AppKit 事件链无关）反算像素，对一下放大镜报的光标像素。
            if let systemCursor = CGEvent(source: nil)?.location,
                let screen = NSScreen.screens.first(where: { $0.jietu_displayID == before.displayID })
            {
                let local = DisplayGeometry.localPoint(fromCG: systemCursor, screen: screen)
                let pixel = CGPoint(
                    x: local.x * frozenShot.effectiveScale,
                    y: (frozenShot.screenFrameInPoints.height - local.y)
                        * frozenShot.effectiveScale
                )
                lines.append(
                    "系统光标=(\(Int(systemCursor.x)),\(Int(systemCursor.y)))cg"
                        + " → 期望像素=(\(Int(pixel.x)),\(Int(pixel.y)))"
                        + " 报告=(\(Int(state.cursorPixel.x)),\(Int(state.cursorPixel.y)))"
                        + " 差=(\(Int(state.cursorPixel.x - pixel.x)),\(Int(state.cursorPixel.y - pixel.y)))"
                )
            }

            let scale = ui.effectiveScale
            let screenHeight = ui.screenFrameInPoints.height

            // 先把放大镜里每格中心的颜色取下来（跳过十字带那一行 / 列，那里有染色）。
            var loupeColors: [String: String] = [:]
            for row in 0..<13 {
                for col in 0..<13 {
                    if col == Int(state.cell.x) || row == Int(state.cell.y) { continue }
                    let localX = state.frame.minX + state.cellSide * (CGFloat(col) + 0.5)
                    let localY = state.frame.minY + state.frame.height
                        - state.cellSide * (CGFloat(row) + 0.5)
                    let shotX = Int((localX * scale).rounded())
                    let shotY = Int(((screenHeight - localY) * scale).rounded())
                    guard
                        let sample = PixelSampler.sample(
                            ui.image, atPixel: CGPoint(x: shotX, y: shotY)
                        )
                    else { continue }
                    loupeColors["\(col),\(row)"] = sample.hexString
                }
            }

            // 在 ±6 像素里搜「哪个偏移能让放大镜每格都和冻结图对上」——这就是偏移量。
            func score(offsetX: Int, offsetY: Int) -> (total: Int, count: Int) {
                var total = 0
                var count = 0
                for (key, loupeHex) in loupeColors {
                    let parts = key.split(separator: ",").compactMap { Int($0) }
                    guard parts.count == 2 else { continue }
                    let sourceX = Int(state.sourceOrigin.x) + parts[0] + offsetX
                    let sourceY = Int(state.sourceOrigin.y) + parts[1] + offsetY
                    guard
                        let frozen = PixelSampler.sample(
                            frozenShot.image, atPixel: CGPoint(x: sourceX, y: sourceY)
                        )
                    else { continue }
                    total += Self.hexDelta(frozen.hexString, loupeHex)
                    count += 1
                }
                return (total, count)
            }

            var best: (offsetX: Int, offsetY: Int, total: Int, count: Int)?
            for offsetY in -6...6 {
                for offsetX in -6...6 {
                    let result = score(offsetX: offsetX, offsetY: offsetY)
                    guard result.count > 0 else { continue }
                    if best == nil || result.total < best!.total {
                        best = (offsetX, offsetY, result.total, result.count)
                    }
                }
            }

            // 逐格明细（只看第一行，便于肉眼核对）
            let zero = score(offsetX: 0, offsetY: 0)
            lines.append("逐格比对 \(zero.count) 格，颜色种类 \(Set(loupeColors.values).count)")
            if let best {
                let avg = best.count > 0 ? Double(best.total) / Double(best.count) : -1
                let zeroAvg = zero.count > 0 ? Double(zero.total) / Double(zero.count) : -1
                lines.append(
                    String(
                        format: "最佳匹配偏移=(%d,%d) 平均差=%.1f；偏移(0,0) 平均差=%.1f",
                        best.offsetX, best.offsetY, avg, zeroAvg
                    )
                )
                if best.offsetX == 0 && best.offsetY == 0 && avg < 4 {
                    lines.append("✓ 放大镜每格 = 冻结图同坐标像素（无偏移）")
                } else {
                    lines.append("✗ 放大镜内容整体偏移了 (\(best.offsetX),\(best.offsetY)) 像素")
                }
            }
            return lines
        }
        return lines
    }

    /// 两个 `#RRGGBB` 之间的通道差之和（0...765）。
    private static func hexDelta(_ lhs: String, _ rhs: String) -> Int {
        func components(_ hex: String) -> [Int] {
            let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard trimmed.count == 6 else { return [0, 0, 0] }
            var values: [Int] = []
            var index = trimmed.startIndex
            for _ in 0..<3 {
                let next = trimmed.index(index, offsetBy: 2)
                values.append(Int(trimmed[index..<next], radix: 16) ?? 0)
                index = next
            }
            return values
        }
        let a = components(lhs)
        let b = components(rhs)
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }
    }

    private static func activeLoupeState(
        _ coordinator: OverlayCoordinator
    ) -> (displayID: CGDirectDisplayID, state: OverlayCanvasView.DebugLoupeState)? {
        coordinator.debugSelections.compactMap { entry in
            guard let state = coordinator.debugLoupeState(displayID: entry.displayID)
            else { return nil }
            return (entry.displayID, state)
        }.first
    }

    private static func postMouse(_ type: CGEventType, at point: CGPoint) {
        CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    private static func runEditorTest(outputDirectory: URL, inline: Bool) {
        Task { @MainActor in
            var report: [String] = []
            do {
                let image = try makeTestImage(width: 260, height: 180)

                // 先量一下工具栏真正需要多宽（SwiftUI 的最小尺寸），再拿它对照现用常量。
                let probe = AnnotationEditorView(
                    baseImage: image,
                    inline: true,
                    onCopy: { _ in }, onSave: { _ in }, onPin: { _, _ in }, onClose: {}
                )
                let probeHost = NSHostingView(rootView: probe)
                report.append(
                    "SwiftUI 最小宽=\(Int(probeHost.fittingSize.width.rounded()))"
                        + " 高=\(Int(probeHost.fittingSize.height.rounded()))"
                )

                // 原地模式：故意用一个比工具栏窄的选区当锚点。
                let anchor: CGRect? = inline
                    ? CGRect(x: 700, y: 560, width: 260, height: 180)
                    : nil
                let controller = AnnotationEditorWindowController(image: image, anchor: anchor)
                retainedEditor = controller
                controller.present()
                report.append(
                    "editor inline=\(inline) image=260x180"
                        + " 工具栏最小宽=\(Int(AnnotationEditorView.toolbarMinWidth))"
                        + " 窗口最小宽=\(Int(AnnotationEditorView.minWindowWidth))"
                )

                try? await Task.sleep(for: .milliseconds(900))
                let snapshots = try await CaptureEngine().captureAllDisplays(
                    excludingOwnApplication: false
                )
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )
                for (index, snapshot) in snapshots.enumerated() {
                    let url = outputDirectory
                        .appendingPathComponent("editor-\(inline ? "inline" : "window")-\(index).png")
                    try writePNG(snapshot.image, to: url)
                    report.append("  display \(snapshot.displayID) -> \(url.path)")
                }
                // 画一个框，再在**框里面**画一个：第二个必须画得出来（不是把第一个拖走）。
                // 用户报过：矩形的命中判定按整块矩形算，框中间一按就变成「选中并移动」。
                controller.close()
                report.append("RESULT: PASS")
                finish(report, code: 0)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    /// 自检用的「最坏底图」：纯白 + 一圈浅灰描边，专治按钮糊在白底里。
    private static func makeWhiteTestImage(width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw CaptureError.emptyImage(0) }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        context.setLineWidth(2)
        context.stroke(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))
        guard let image = context.makeImage() else { throw CaptureError.emptyImage(0) }
        return image
    }

    /// 自检用的一张**有字**的图：钉图的「翻译」要先认出字才谈得上翻译。
    private static func makeTextTestImage(width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw CaptureError.emptyImage(0) }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let title = "System Requirements"
        let body = "Optimized for Apple Silicon. Runs great on Intel."
        (title as NSString).draw(
            at: NSPoint(x: 40, y: CGFloat(height) - 70),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 30, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
        )
        (body as NSString).draw(
            at: NSPoint(x: 40, y: CGFloat(height) - 110),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.darkGray,
            ]
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw CaptureError.emptyImage(0) }
        return image
    }

    /// 自检用的小图：彩色块 + 斜线，够看出缩放 / 裁切。
    /// 自检用的小图（app 级自检也要用）。
    static func makeTestImage(width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw CaptureError.emptyImage(0) }
        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let colors: [CGColor] = [
            CGColor(red: 0.95, green: 0.4, blue: 0.4, alpha: 1),
            CGColor(red: 0.4, green: 0.7, blue: 0.95, alpha: 1),
            CGColor(red: 0.5, green: 0.85, blue: 0.5, alpha: 1),
        ]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color)
            let size = CGFloat(min(width, height) / 4)
            context.fill(
                CGRect(
                    x: 8 + CGFloat(index) * (size + 8), y: CGFloat(height) - size - 8,
                    width: size, height: size
                )
            )
        }
        guard let image = context.makeImage() else { throw CaptureError.emptyImage(0) }
        return image
    }

    private static var retainedEditor: AnnotationEditorWindowController?

    private static func runScrollProbe(spec: String, outputDirectory: URL) {        Task { @MainActor in
            var report: [String] = []
            do {
                let engine = CaptureEngine()
                let rect = parseRect(spec) ?? CGRect(x: 400, y: 400, width: 700, height: 500)
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
                    ?? NSScreen.main ?? NSScreen.screens[0]
                guard let displayID = screen.jietu_displayID else { throw CaptureError.noDisplays }
                let center = DisplayGeometry.cgPoint(
                    fromLocal: CGPoint(x: rect.midX, y: screen.frame.height - rect.midY),
                    screen: screen
                )
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )
                let capturer = try await engine.makeRegionCapturer(
                    displayID: displayID, regionInPoints: rect
                )
                report.append(
                    "display=\(displayID) rect=\(describe(rect))"
                        + String(format: " center(cg)=(%.0f,%.0f)", center.x, center.y)
                        + String(format: " 鼠标=(%.0f,%.0f)", mouse.x, mouse.y)
                )

                // 用户报过「自动滚动时鼠标挪不动」：先查合成滚动会不会把光标拽回选区中心。
                // 先把光标挪到选区**外面**，再发一次带 location 的合成滚动，看它跑不跑。
                let awayPoint = CGPoint(x: center.x - 500, y: center.y - 300)
                postMouse(.mouseMoved, at: awayPoint)
                try? await Task.sleep(for: .milliseconds(250))
                let cursorBefore = NSEvent.mouseLocation
                Self.scrollEvent(
                    units: .pixel, value: -67, continuous: nil, location: center
                )?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(250))
                let cursorAfter = NSEvent.mouseLocation
                report.append(
                    String(
                        format: "光标漂移：发前 (%.0f,%.0f) → 发后 (%.0f,%.0f)，位移 %.0f pt"
                            + "（选区中心 (%.0f,%.0f)；期望 0）",
                        cursorBefore.x, cursorBefore.y, cursorAfter.x, cursorAfter.y,
                        hypot(cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y),
                        center.x, DisplayGeometry.referenceHeight - center.y
                    )
                )

                // 大部分 App 只把滚轮送给「指针下面的窗口」，所以把光标也挪进选区。
                CGEvent(
                    mouseEventSource: CGEventSource(stateID: .hidSystemState),
                    mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left
                )?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(250))

                // 光标停在选区里、但**不在中心**：位置跟着光标走的做法不该把它挪到中心。
                let insideOffset = CGPoint(x: center.x - 60, y: center.y - 40)

                /// 每次发 3 步；顺带量「光标被拽走多少」——用户报的就是这个。
                let variants: [(String, () -> Void)] = [
                    ("location=选区中心（旧做法）", {
                        for _ in 0..<3 {
                            Self.scrollEvent(
                                units: .pixel, value: -67, continuous: nil, location: center
                            )?.post(tap: .cghidEventTap)
                        }
                    }),
                    ("location=光标（新做法）", {
                        for _ in 0..<3 {
                            let cursor = DisplayGeometry.flipY(NSEvent.mouseLocation)
                            Self.scrollEvent(
                                units: .pixel, value: -67, continuous: nil, location: cursor
                            )?.post(tap: .cghidEventTap)
                        }
                    }),
                ]

                for (index, variant) in variants.enumerated() {
                    // 先把页滚回上面，每个变体都在同一起点起跑。
                    for _ in 0..<4 {
                        Self.scrollEvent(units: .line, value: 5, continuous: false, location: center)?
                            .post(tap: .cghidEventTap)
                        try? await Task.sleep(for: .milliseconds(80))
                    }
                    try? await Task.sleep(for: .milliseconds(400))

                    let before = try await capturer.capture()
                    let beforeBitmap = ScrollStitcher.BitmapData(image: before)
                    try writePNG(
                        before,
                        to: outputDirectory.appendingPathComponent("probe-\(index)-before.png")
                    )
                    // 光标放在选区内、但离中心 60/40pt：被拽到中心才量得出来（也跟着事件位置走）。
                    postMouse(.mouseMoved, at: insideOffset)
                    try? await Task.sleep(for: .milliseconds(200))
                    let cursorBefore = NSEvent.mouseLocation
                    variant.1()
                    try? await Task.sleep(for: .milliseconds(500))
                    let cursorAfter = NSEvent.mouseLocation
                    let drift = hypot(
                        cursorAfter.x - cursorBefore.x, cursorAfter.y - cursorBefore.y
                    )
                    let after = try await capturer.capture()
                    let afterBitmap = ScrollStitcher.BitmapData(image: after)
                    let url = outputDirectory.appendingPathComponent("probe-\(index)-after.png")
                    try writePNG(after, to: url)
                    let diff = (beforeBitmap != nil && afterBitmap != nil)
                        ? meanDifference(beforeBitmap!, afterBitmap!) : -1
                    report.append(
                        String(format: "变体 %d（%@）变化=%.2f 光标漂移=%.0fpt", index, variant.0, diff, drift)
                            + " Vision=\(String(describing: ScrollStitcher.offset(previous: before, next: after)))"
                    )
                }
                report.append("RESULT: PASS")
                finish(report, code: 0)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    private static func scrollEvent(
        units: CGScrollEventUnit, value: Int32, continuous: Bool?, location: CGPoint?,
        phase: CGScrollPhase? = nil, windowNumber: CGWindowID? = nil
    ) -> CGEvent? {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source, units: units, wheelCount: 1,
                wheel1: value, wheel2: 0, wheel3: 0
            )
        else { return nil }
        if let continuous {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        }
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        if let location {
            event.location = location
        }
        if let windowNumber {
            event.setIntegerValueField(
                .mouseEventWindowUnderMousePointer, value: Int64(windowNumber)
            )
        }
        return event
    }

    private static func runFramesTest(spec: String, outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            do {
                let engine = CaptureEngine()
                let rect = parseRect(spec) ?? CGRect(x: 400, y: 400, width: 700, height: 500)
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
                    ?? NSScreen.main ?? NSScreen.screens[0]
                guard let displayID = screen.jietu_displayID else { throw CaptureError.noDisplays }
                let center = DisplayGeometry.cgPoint(
                    fromLocal: CGPoint(x: rect.midX, y: screen.frame.height - rect.midY),
                    screen: screen
                )
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                let capturer = try await engine.makeRegionCapturer(
                    displayID: displayID, regionInPoints: rect
                )
                let step = AutoScroller.stepPoints(forHeight: rect.height)
                let scroller = AutoScroller(
                    center: center,
                    blockingRect: CGRect(
                        x: center.x - rect.width / 2, y: center.y - rect.height / 2,
                        width: rect.width, height: rect.height
                    ),
                    stepPoints: step
                )
                let withBlocker = CommandLine.arguments.contains("--with-blocker")
                report.append(
                    "display=\(displayID) rect=\(describe(rect)) step=\(step)pt"
                        + " axTrusted=\(AccessibilityPermission.isGranted)"
                        + " inputBlocker=\(withBlocker)"
                )
                if withBlocker {
                    scroller.installInputBlocker()
                }

                var previous: ScrollStitcher.BitmapData?
                var previousFrame: CGImage?
                var session: ScrollStitcher.Session?
                for index in 0...5 {
                    if index > 0 {
                        // 事件位置跟着光标走（固定发中心会把光标拽过去）。
                        scroller.postScrollStep(at: DisplayGeometry.flipY(NSEvent.mouseLocation))
                        try? await Task.sleep(for: .milliseconds(450))
                    }
                    let frame = try await capturer.capture()
                    let bitmap = ScrollStitcher.BitmapData(image: frame)
                    let url = outputDirectory.appendingPathComponent("frame-\(index).png")
                    try writePNG(frame, to: url)

                    var line = "frame \(index) \(frame.width)x\(frame.height)"
                        + " bitmap=\(bitmap != nil)"
                        + " mean=\(String(format: "%.3f", meanLuminance(frame)))"
                    if let bitmap, let previous {
                        line += " 与上帧平均差=\(String(format: "%.2f", meanDifference(previous, bitmap)))"
                    }
                    if let previousFrame {
                        line += " Vision位移="
                            + String(describing: ScrollStitcher.offset(previous: previousFrame, next: frame))
                    }
                    if let session {
                        switch session.append(frame: frame) {
                        case .appended(let h): line += " 拼接=+\(h)"
                        case .noNewContent: line += " 拼接=无新内容"
                        case .atLimit: line += " 拼接=到上限"
                        }
                    } else {
                        session = ScrollStitcher.Session(firstFrame: frame, maxFrames: 120)
                    }
                    report.append(line)
                    previous = bitmap
                    previousFrame = frame
                }

                // 尽量把页面滚回原处，别把用户的阅读位置留在别处。
                for _ in 0..<5 {
                    scroller.postScrollStep(
                        at: DisplayGeometry.flipY(NSEvent.mouseLocation), reversed: true
                    )
                    try? await Task.sleep(for: .milliseconds(150))
                }
                report.append("RESULT: PASS")
                finish(report, code: 0)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    /// 两帧之间的平均通道差（0...255），用来看滚动到底推动了没有。
    private static func meanDifference(
        _ a: ScrollStitcher.BitmapData, _ b: ScrollStitcher.BitmapData
    ) -> Double {
        guard a.width == b.width, a.height == b.height else { return -1 }
        var total = 0
        var count = 0
        let columns = stride(from: 0, to: a.width, by: max(1, a.width / 24))
        let rows = stride(from: 0, to: a.height, by: max(1, a.height / 24))
        for y in rows {
            for x in columns {
                let p = a.pixel(x: x, y: y)
                let q = b.pixel(x: x, y: y)
                total += abs(Int(p.r) - Int(q.r)) + abs(Int(p.g) - Int(q.g))
                    + abs(Int(p.b) - Int(q.b))
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count * 3) : -1
    }

    private static func runSessionTest(spec: String, outputDirectory: URL) {        Task { @MainActor in
            var report: [String] = []
            do {
                let engine = CaptureEngine()
                let rect = parseRect(spec) ?? CGRect(x: 400, y: 400, width: 700, height: 500)
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
                    ?? NSScreen.main ?? NSScreen.screens[0]
                guard let displayID = screen.jietu_displayID else {
                    throw CaptureError.noDisplays
                }
                let frame = screen.frame
                let globalRect = CGRect(
                    origin: DisplayGeometry.cgPoint(fromLocal: rect.origin, screen: screen),
                    size: rect.size
                )
                report.append(
                    "display=\(displayID) rect(top-left)=\(describe(rect))"
                        + " cgRect=\(describe(globalRect))"
                )

                let session = ScrollingCaptureSession(
                    engine: engine,
                    target: ScrollingCaptureSession.Target(
                        displayID: displayID,
                        regionInPoints: rect,
                        regionInGlobalCGPoints: globalRect
                    )
                )
                session.mode = .automatic
                session.idleIntervalsToStop = 4

                var heights: [Int] = []
                var previews = 0
                session.onProgress = { heights.append($0) }
                session.onPreview = { image in
                    previews += 1
                    let url = outputDirectory.appendingPathComponent("preview-\(previews).png")
                    try? FileManager.default.createDirectory(
                        at: outputDirectory, withIntermediateDirectories: true
                    )
                    try? writePNG(image, to: url)
                }
                report.append(
                    "step=\(AutoScroller.stepPoints(forHeight: rect.height))pt"
                        + " axTrusted=\(AccessibilityPermission.isGranted)"
                )

                let started = Date()
                let image = await session.run()
                report.append(
                    String(format: "耗时 %.2fs", Date().timeIntervalSince(started))
                        + " 进度拍数=\(heights.count) 高度序列=\(heights)"
                        + " 预览帧=\(previews)"
                )
                if let image {
                    try FileManager.default.createDirectory(
                        at: outputDirectory, withIntermediateDirectories: true
                    )
                    let url = outputDirectory.appendingPathComponent("stitched.png")
                    try writePNG(image, to: url)
                    report.append("拼接结果 \(image.width)x\(image.height) -> \(url.path)")
                } else {
                    report.append("拼接结果 nil（就是弹「没有捕获到滚动内容」那条）")
                }
                // 顺手把当前这一帧存下来，看看抓的到底是什么。
                if let probe = try? await engine.captureRegion(
                    displayID: displayID, regionInPoints: rect
                ) {
                    let url = outputDirectory.appendingPathComponent("probe.png")
                    try? writePNG(probe, to: url)
                    report.append("单帧 \(probe.width)x\(probe.height) -> \(url.path)")
                }
                report.append("RESULT: PASS")
                finish(report, code: 0)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    private static func runChromeTest(spec: String, outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            do {
                let engine = CaptureEngine()
                let snapshots = try await engine.captureAllDisplays()
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                let rect = parseRect(spec) ?? CGRect(x: 400, y: 400, width: 700, height: 500)

                // 鼠标在哪块屏就在哪块屏取景（和真实流程一致）。
                let mouse = NSEvent.mouseLocation
                let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
                    ?? NSScreen.main ?? NSScreen.screens[0]
                guard let displayID = screen.jietu_displayID,
                    let snapshot = snapshots.first(where: { $0.displayID == displayID })
                else { throw CaptureError.noDisplays }

                let coordinator = OverlayCoordinator()
                retainedCoordinator = coordinator
                coordinator.purpose = .regionPick
                coordinator.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: false
                )
                // SCK 的 rect 是「原点左上」，画布选区是「原点左下」，换算一次才对齐。
                let canvasRect = CGRect(
                    x: rect.minX,
                    y: snapshot.screenFrameInPoints.height - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
                coordinator.debugSetSelection(canvasRect, displayID: displayID)
                coordinator.beginScrollCaptureChrome()
                report.append(
                    "display=\(displayID) frame=\(describe(snapshot.screenFrameInPoints))"
                        + " selection(top-left)=\(describe(rect))"
                        + " chrome=on"
                )
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                try? await Task.sleep(for: .milliseconds(600))
                dumpOwnWindows(label: "chrome")
                report.append(contentsOf: capturedWindowLines())

                // ① 本 App 被排除：应当拍到遮罩「下面」的真实画面（不是黑）。
                let excluded = try await engine.captureRegion(
                    displayID: displayID, regionInPoints: rect
                )
                let excludedURL = outputDirectory.appendingPathComponent("chrome-excluded.png")
                try writePNG(excluded, to: excludedURL)
                report.append(
                    "排除本 App   \(excluded.width)x\(excluded.height)"
                        + " mean=\(String(format: "%.3f", meanLuminance(excluded)))"
                        + " -> \(excludedURL.lastPathComponent)"
                )

                // ② 不排除：拍到的是遮罩自己（取景框该是「透明 + 压暗」，不该是纯黑）。
                let included = try await engine.captureRegion(
                    displayID: displayID, regionInPoints: rect,
                    excludingOwnApplication: false
                )
                let includedURL = outputDirectory.appendingPathComponent("chrome-included.png")
                try writePNG(included, to: includedURL)
                report.append(
                    "含本 App     \(included.width)x\(included.height)"
                        + " mean=\(String(format: "%.3f", meanLuminance(included)))"
                        + " -> \(includedURL.lastPathComponent)"
                )

                // ③ 往选区中央发一步合成滚动：被排除的那条路上，画面应当随之变化。
                let screenFrame = snapshot.screenFrameInPoints
                let center = DisplayGeometry.cgPoint(
                    fromLocal: CGPoint(x: rect.midX, y: screenFrame.height - rect.midY),
                    screen: screen
                )
                let scroller = AutoScroller(
                    center: center,
                    blockingRect: CGRect(
                        x: center.x - rect.width / 2, y: center.y - rect.height / 2,
                        width: rect.width, height: rect.height
                    ),
                    stepPoints: AutoScroller.stepPoints(forHeight: rect.height)
                )
                postScrollSteps(scroller, count: 4)
                try? await Task.sleep(for: .milliseconds(700))

                let afterScroll = try await engine.captureRegion(
                    displayID: displayID, regionInPoints: rect
                )
                let afterURL = outputDirectory.appendingPathComponent("chrome-after-scroll.png")
                try writePNG(afterScroll, to: afterURL)
                report.append(
                    "滚动后       \(afterScroll.width)x\(afterScroll.height)"
                        + " mean=\(String(format: "%.3f", meanLuminance(afterScroll)))"
                        + " 内容变化=\(!samePixels(excluded, afterScroll))"
                        + " -> \(afterURL.lastPathComponent)"
                )

                coordinator.cancel()
                report.append("RESULT: PASS")
                finish(report, code: 0)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    private static func postScrollSteps(_ scroller: AutoScroller, count: Int) {
        for _ in 0..<count {
            scroller.postScrollStep(at: DisplayGeometry.flipY(NSEvent.mouseLocation))
            usleep(120_000)
        }
    }

    /// 自检用：列出本进程在屏幕上的窗口（层级 / 位置 / alpha）。
    private static func capturedWindowLines() -> [String] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return info
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
            .map { window in
                let layer = window[kCGWindowLayer as String] as? Int ?? -999
                let alpha = window[kCGWindowAlpha as String] as? Double ?? -1
                let b = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                return "  自身窗口 layer=\(layer) alpha=\(alpha)"
                    + " x=\(Int(b["X"] ?? 0)) y=\(Int(b["Y"] ?? 0))"
                    + " w=\(Int(b["Width"] ?? 0)) h=\(Int(b["Height"] ?? 0))"
            }
    }

    /// 把 `x,y,w,h` 解析成矩形（显示器内点坐标、原点左上——与滚动长图的 sourceRect 约定一致）。
    private static func parseRect(_ spec: String) -> CGRect? {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private static func runRegionTest(spec: String, outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            do {
                let engine = CaptureEngine()
                let full = try await engine.captureAllDisplays()
                guard !full.isEmpty else { throw CaptureError.noDisplays }
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                let rect = parseRect(spec) ?? CGRect(x: 0, y: 0, width: 400, height: 300)
                report.append("screens=\(NSScreen.screens.count) rect(top-left, points)=\(describe(rect))")

                for snapshot in full {
                    let frame = snapshot.screenFrameInPoints
                    let scale = snapshot.effectiveScale
                    report.append(
                        "display=\(snapshot.displayID) frame=\(describe(frame))"
                            + " scale=\(String(format: "%.2f", scale))"
                    )

                    // 1) SCK 按 sourceRect 直接抓（滚动长图走的就是这条）。
                    let direct = try await engine.captureRegion(
                        displayID: snapshot.displayID, regionInPoints: rect
                    )
                    let directURL = outputDirectory
                        .appendingPathComponent("region-sck-\(snapshot.displayID).png")
                    try writePNG(direct, to: directURL)
                    report.append(
                        "  sck  \(direct.width)x\(direct.height)"
                            + " mean=\(String(format: "%.1f", meanLuminance(direct)))"
                            + " -> \(directURL.lastPathComponent)"
                    )

                    // 2) 整屏抓 → 按同一块区域裁（已知正确的那条路）。
                    let bottomLeft = CGRect(
                        x: rect.minX,
                        y: frame.height - rect.maxY,
                        width: rect.width,
                        height: rect.height
                    )
                    let crop = CaptureOutput.crop(snapshot, toLocalRect: bottomLeft)
                    if let crop {
                        let cropURL = outputDirectory
                            .appendingPathComponent("region-crop-\(snapshot.displayID).png")
                        try writePNG(crop, to: cropURL)
                        report.append(
                            "  crop \(crop.width)x\(crop.height)"
                                + " mean=\(String(format: "%.1f", meanLuminance(crop)))"
                                + " -> \(cropURL.lastPathComponent)"
                        )
                        report.append(
                            "  同尺寸=\(crop.width == direct.width && crop.height == direct.height)"
                                + " 同内容=\(Self.samePixels(crop, direct))"
                        )
                    } else {
                        report.append("  crop 失败（local=\(describe(bottomLeft))）")
                    }
                }
                report.append("RESULT: PASS")
                finish(report, code: 0)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    /// 稀疏采样比像素：抓错区域时这里会直接报 false。
    /// 先各自画进同一个 64×64 RGBA 上下文再比，免受行距 / 色彩空间差异干扰。
    private static func samePixels(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width > 1, b.width > 1 else { return false }
        let width = 64
        let height = 64
        func raster(_ image: CGImage) -> [UInt8]? {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard
                let context = CGContext(
                    data: &pixels, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return pixels
        }
        guard let pa = raster(a), let pb = raster(b) else { return false }
        for index in stride(from: 0, to: pa.count, by: 4) {
            if abs(Int(pa[index]) - Int(pb[index])) > 6 { return false }
            if abs(Int(pa[index + 1]) - Int(pb[index + 1])) > 6 { return false }
            if abs(Int(pa[index + 2]) - Int(pb[index + 2])) > 6 { return false }
        }
        return true
    }

    private static func runCaptureTest(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            report.append("preflight.screenCapture = \(ScreenCapturePermission.isGranted)")
            report.append("screens.count = \(NSScreen.screens.count)")

            for (index, screen) in NSScreen.screens.enumerated() {
                let displayID = screen.jietu_displayID
                let cgBounds = displayID.map { Self.describe(CGDisplayBounds($0)) } ?? "n/a"
                report.append(
                    "screen[\(index)] id=\(displayID.map(String.init) ?? "nil")"
                        + " appkitFrame=\(Self.describe(screen.frame))"
                        + " cgDisplayBounds=\(cgBounds)"
                        + " backingScale=\(screen.backingScaleFactor)"
                )
            }

            do {
                let snapshots = try await CaptureEngine().captureAllDisplays()
                report.append("captured \(snapshots.count) snapshot(s)")

                try FileManager.default.createDirectory(
                    at: outputDirectory,
                    withIntermediateDirectories: true
                )

                for (index, snapshot) in snapshots.enumerated() {
                    let name = String(format: "display-%d-%u.png", index, snapshot.displayID)
                    let url = outputDirectory.appendingPathComponent(name)
                    try Self.writePNG(snapshot.image, to: url)
                    report.append(
                        "  [\(index)] displayID=\(snapshot.displayID)"
                            + " points=\(Self.describe(snapshot.screenFrameInPoints))"
                            + " pixels=\(Int(snapshot.pixelSize.width))x\(Int(snapshot.pixelSize.height))"
                            + " nominalScale=\(snapshot.nominalScaleFactor)"
                            + " effectiveScale=\(String(format: "%.4f", snapshot.effectiveScale))"
                            + " file=\(url.path)"
                    )
                }
                report.append("RESULT: PASS")
                Self.finish(report, code: 0)
            } catch {
                report.append("error: \(error.localizedDescription)")
                if let captureError = error as? CaptureError {
                    report.append("recovery: \(captureError.recoverySuggestion ?? "-")")
                }
                report.append("RESULT: FAIL")
                Self.finish(report, code: 1)
            }
        }
    }

    private static func runOverlayTest(duration: Double, outputDirectory: URL) {
        Task { @MainActor in
            do {
                let snapshots = try await CaptureEngine().captureAllDisplays()
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                print("windows on screen = \(windows.count)")
                for window in windows.prefix(5) {
                    print(
                        "  win=\(window.windowID) owner=\"\(window.ownerName)\""
                            + " title=\"\(window.title)\" cgFrame=\(describe(window.frameInCGPoints))"
                    )
                }

                let coordinator = OverlayCoordinator()
                self.retainedCoordinator = coordinator

                // 基线：不含自身窗口，等于「用户看到的原始画面」。
                let baseline = try await CaptureEngine().captureAllDisplays()

                coordinator.onFinish = { outcome in
                    // 自检里不退出，否则会掩盖「谁把遮罩关掉了」这个问题。
                    switch outcome {
                    case .cancelled:
                        print("overlay outcome=cancelled")
                    case .captured(let image, let displayID, _, _):
                        print("overlay outcome=captured \(image.width)x\(image.height) display=\(displayID)")
                        try? FileManager.default.createDirectory(
                            at: outputDirectory,
                            withIntermediateDirectories: true
                        )
                        let url = outputDirectory.appendingPathComponent("cropped-\(displayID).png")
                        try? Self.writePNG(image, to: url)
                        print("  cropped -> \(url.path)")
                    case .windowCaptured(let window, let snapshot):
                        print("overlay outcome=windowCaptured \(window.displayName) on display=\(snapshot.displayID)")
                    }
                }
                coordinator.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: false
                )
                print("overlay presented for \(snapshots.count) display(s), holding \(duration)s")

                try? await Task.sleep(for: .milliseconds(700))
                dumpOwnWindows(label: "after 0.7s")

                // 留出时间给外部工具注入鼠标拖拽，再自拍一张，
                // 用来目视检查选区边框 / handle / 尺寸标签 / 放大镜。
                try? await Task.sleep(for: .milliseconds(1500))
                print("--- self-capture with overlay ---")
                let withOverlay = (try? await CaptureEngine()
                    .captureAllDisplays(excludingOwnApplication: false)) ?? []
                try? FileManager.default.createDirectory(
                    at: outputDirectory,
                    withIntermediateDirectories: true
                )
                for (index, snapshot) in withOverlay.enumerated() {
                    let url = outputDirectory
                        .appendingPathComponent("overlay-self-\(index).png")
                    try? Self.writePNG(snapshot.image, to: url)
                    print("  overlay-self[\(index)] -> \(url.path)")
                }

                // 受控验证压暗层：同一批像素，比较「遮罩后」与「基线」的亮度比。
                // 选区内部应≈1.0（不压暗），外部应≈0.55（45% 黑）。
                // 无选区但吸附到满屏窗口时，整个画面都该是≈1.0。
                for entry in coordinator.debugSelections {
                    guard let baseImage = baseline.first(where: { $0.displayID == entry.displayID })?.image,
                        let overlayImage = withOverlay.first(where: { $0.displayID == entry.displayID })?.image
                    else { continue }

                    let centerRect = CGRect(
                        x: overlayImage.width / 4,
                        y: overlayImage.height / 2,
                        width: 400,
                        height: 200
                    )
                    Self.reportDim(
                        "center ",
                        baseline: baseImage,
                        overlay: overlayImage,
                        rect: centerRect
                    )

                    guard let localRect = entry.localRect,
                        let snapshot = snapshots.first(where: { $0.displayID == entry.displayID })
                    else {
                        print("  display \(entry.displayID): 无选区（只报了 center）")
                        continue
                    }
                    let pixelRect = Self.pixelRect(forLocalRect: localRect, snapshot: snapshot)
                    let stripWidth = max(40, min(240, pixelRect.width * 0.35))
                    let outsideRect = CGRect(
                        x: pixelRect.midX - stripWidth / 2,
                        y: max(0, pixelRect.minY - 70),
                        width: stripWidth,
                        height: 60
                    )
                    print("  display \(entry.displayID) selection=\(describe(localRect))")
                    Self.reportDim("inside ", baseline: baseImage, overlay: overlayImage, rect: pixelRect)
                    Self.reportDim("outside", baseline: baseImage, overlay: overlayImage, rect: outsideRect)
                }

                // 初始状态（全程没人动过鼠标）：鼠标所在窗口当场就该是亮的，
                // 而且**不准带绿色**——吸附预览以前压了 6% 绿，窗口一大就整屏泛绿。
                let cursor = NSEvent.mouseLocation
                for snapshot in withOverlay {
                    guard snapshot.screenFrameInPoints.contains(cursor),
                        let base = baseline.first(where: { $0.displayID == snapshot.displayID })
                    else { continue }
                    print(
                        String(
                            format: "光标处（鼠标所在窗口）：亮度 %.3f → %.3f，绿偏移 %.3f → %.3f",
                            Self.luminance(in: base, at: cursor, size: 24),
                            Self.luminance(in: snapshot, at: cursor, size: 24),
                            Self.greenBias(in: base, at: cursor, size: 24),
                            Self.greenBias(in: snapshot, at: cursor, size: 24)
                        )
                    )
                    print("  期望：亮度基本不变（窗口被点亮、没被压暗），绿偏移也基本不变（没有染色）")
                }

                try? await Task.sleep(for: .seconds(duration))
                coordinator.cancel()
                Self.finish(["overlay held \(duration)s then dismissed", "RESULT: PASS"], code: 0)
            } catch {
                Self.finish(["error: \(error.localizedDescription)", "RESULT: FAIL"], code: 1)
            }
        }
    }

    /// 直接向 WindowServer 查询自己的窗口是否真的在屏幕上。
    private static func dumpOwnWindows(label: String) {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let own = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        print("--- \(label): \(own.count) own window(s) on screen ---")
        for window in own {
            let number = window[kCGWindowNumber as String] as? Int ?? -1
            let layer = window[kCGWindowLayer as String] as? Int ?? -999
            let alpha = window[kCGWindowAlpha as String] as? Double ?? -1
            let sharing = window[kCGWindowSharingState as String] as? Int ?? -1
            let name = window[kCGWindowName as String] as? String ?? ""
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            print(
                "  win=\(number) layer=\(layer) alpha=\(alpha) sharingState=\(sharing)"
                    + " name=\"\(name)\" bounds=\(bounds)"
            )
        }
    }

    /// 遮罩测试期间必须有人持有 coordinator，否则窗口会被立刻释放。
    private static var retainedCoordinator: OverlayCoordinator?
    private static var retainedOnboarding: OnboardingWindowController?

    private static func runOnboardingTest(duration: Double) {
        Task { @MainActor in
            let controller = OnboardingWindowController()
            self.retainedOnboarding = controller
            controller.present()
            print("onboarding presented, permissionGranted=\(ScreenCapturePermission.isGranted)")
            print("policy=\(NSApp.activationPolicy().rawValue) isActive=\(NSApp.isActive)")

            try? await Task.sleep(for: .milliseconds(800))
            let windows = NSApp.windows
            print("NSApp.windows.count=\(windows.count)")
            for window in windows {
                print(
                    "  title=\(window.title) visible=\(window.isVisible)"
                        + " frame=\(Self.describe(window.frame))"
                        + " alpha=\(window.alphaValue) level=\(window.level.rawValue)"
                        + " class=\(type(of: window))"
                )
            }
            dumpOwnWindows(label: "onboarding")

            // 外部 `screencapture` 抓不到本 App 的窗口，只能自拍取证。
            print("--- self-capture with own windows included ---")
            let snapshots = (try? await CaptureEngine()
                .captureAllDisplays(excludingOwnApplication: false)) ?? []
            for (index, snapshot) in snapshots.enumerated() {
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("jietu-onboarding-self-\(index).png")
                try? Self.writePNG(snapshot.image, to: url)
                print("  self-capture[\(index)] -> \(url.path)")
            }

            try? await Task.sleep(for: .seconds(duration))
            Self.finish(["onboarding held \(duration)s", "RESULT: PASS"], code: 0)
        }
    }

    /// 写 PNG（app 级自检也要用）。
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw CaptureError.emptyImage(0)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.emptyImage(0)
        }
    }

    /// 自检报告里的矩形格式（两批自检共用）。
    static func describe(_ rect: CGRect) -> String {
        String(
            format: "(%.0f,%.0f %.0fx%.0f)",
            rect.origin.x, rect.origin.y, rect.width, rect.height
        )
    }

    /// 受控对比：同一批像素在「基线」与「遮罩后」两张图里的亮度比。
    private static func reportDim(
        _ label: String,
        baseline: CGImage,
        overlay: CGImage,
        rect: CGRect
    ) {
        guard !rect.isEmpty else {
            print("    \(label): 采样区为空，跳过")
            return
        }
        let base = meanLuminance(baseline, pixelRect: rect)
        let over = meanLuminance(overlay, pixelRect: rect)
        let ratio = base > 0.0001 ? over / base : 0
        print(
            String(
                format: "    %@ baseline=%.4f overlay=%.4f ratio=%.3f",
                label, base, over, ratio
            )
        )
    }

    /// local（原点左下、point）→ 图像像素矩形（原点左上）。
    private static func pixelRect(forLocalRect rect: CGRect, snapshot: DisplaySnapshot) -> CGRect {
        let scale = snapshot.effectiveScale
        return CGRect(
            x: rect.minX * scale,
            y: (snapshot.screenFrameInPoints.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        .integral
        .intersection(CGRect(origin: .zero, size: snapshot.pixelSize))
    }

    /// 指定像素区域的平均亮度。`cropping` 与调用方都用「原点左上」的像素坐标，
    /// 所以这里不需要再做 Y 翻转。
    private static func meanLuminance(_ image: CGImage, pixelRect: CGRect? = nil) -> Double {
        let rgb = meanRGB(image, pixelRect: pixelRect)
        return 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    }

    /// 指定屏幕点（AppKit 全局坐标）附近一块的「绿偏移」均值（G − R）。
    ///
    /// 用来判断某个点是不是**绿色**——绿色对勾在灰度图上只比黑图标亮一点，
    /// 光看亮度分不出来，看 G−R 才有分辨率。
    private static func greenBias(
        in snapshot: DisplaySnapshot, at center: CGPoint, size: CGFloat
    ) -> Double {
        let rgb = meanRGB(snapshot.image, pixelRect: pixelRect(in: snapshot, at: center, size: size))
        return rgb.green - rgb.red
    }

    /// 「蓝偏移」（B−R）：识别文本按钮点亮后是品牌蓝实心，探测它比探绿勾更稳。
    private static func blueBias(
        in snapshot: DisplaySnapshot, at center: CGPoint, size: CGFloat
    ) -> Double {
        let rgb = meanRGB(snapshot.image, pixelRect: pixelRect(in: snapshot, at: center, size: size))
        return rgb.blue - rgb.red
    }

    /// 屏幕点（AppKit 全局坐标）→ 截图像素矩形。
    private static func pixelRect(
        in snapshot: DisplaySnapshot, at center: CGPoint, size: CGFloat
    ) -> CGRect {
        let scale = snapshot.effectiveScale
        let local = CGPoint(
            x: center.x - snapshot.screenFrameInPoints.minX,
            y: center.y - snapshot.screenFrameInPoints.minY
        )
        return CGRect(
            x: (local.x - size / 2) * scale,
            y: (snapshot.screenFrameInPoints.height - local.y - size / 2) * scale,
            width: size * scale,
            height: size * scale
        )
    }

    private static func meanRGB(
        _ image: CGImage, pixelRect: CGRect? = nil
    ) -> (red: Double, green: Double, blue: Double) {
        let imageBounds = CGRect(
            origin: .zero,
            size: CGSize(width: image.width, height: image.height)
        )
        let target = (pixelRect ?? imageBounds).intersection(imageBounds)
        guard !target.isEmpty, let crop = image.cropping(to: target) else { return (-1, -1, -1) }

        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return (-1, -1, -1) }

        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red = 0.0
        var green = 0.0
        var blue = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            red += Double(pixels[index]) / 255
            green += Double(pixels[index + 1]) / 255
            blue += Double(pixels[index + 2]) / 255
        }

        let count = Double(width * height)
        return (red / count, green / count, blue / count)
    }

    /// 自检报告输出（`--selftest-` 与 `--selftest-app-` 两批共用）。
    static func finish(_ lines: [String], code: Int32) {
        print("=== Jietu selftest ===")
        for line in lines { print(line) }
        print("======================")
        fflush(stdout)
        exit(code)
    }
}

#endif
