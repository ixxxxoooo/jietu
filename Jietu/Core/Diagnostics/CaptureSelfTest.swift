import AppKit
import ImageIO
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
enum CaptureSelfTest {
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

        case "--selftest-loupe":
            // 选区放大镜：合成一次「按下 → 拖动 → 停住」，截图看网格 / 读数面板。
            runLoupeTest(
                spec: value ?? "700,600,600,300",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
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
    private static func runLoupeTest(spec: String, outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            do {
                let engine = CaptureEngine()
                let snapshots = try await engine.captureAllDisplays()
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                let parts = spec.split(separator: ",").compactMap { Double($0) }
                let start = CGPoint(x: parts.count == 4 ? parts[0] : 700, y: parts.count == 4 ? parts[1] : 600)
                let delta = CGSize(
                    width: parts.count == 4 ? parts[2] : 600,
                    height: parts.count == 4 ? parts[3] : 300
                )

                let coordinator = OverlayCoordinator()
                retainedCoordinator = coordinator
                coordinator.purpose = .screenshot
                coordinator.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: false
                )
                report.append(
                    "overlay presented; drag \(describe(CGRect(origin: start, size: delta)))"
                )
                try? await Task.sleep(for: .milliseconds(600))

                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                // 按下 → 拖到位 → 停住不动（放大镜要跟着光标，并显示选区尺寸）。
                postMouse(.mouseMoved, at: start)
                try? await Task.sleep(for: .milliseconds(120))
                postMouse(.leftMouseDown, at: start)
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
                for (index, snapshot) in dragging.enumerated() {
                    let url = outputDirectory
                        .appendingPathComponent("loupe-dragging-\(index).png")
                    try writePNG(snapshot.image, to: url)
                    report.append("拖动中 display \(snapshot.displayID) -> \(url.lastPathComponent)")
                }

                postMouse(.leftMouseUp, at: end)
                try? await Task.sleep(for: .milliseconds(500))
                let released = try await engine.captureAllDisplays(
                    excludingOwnApplication: false
                )
                for (index, snapshot) in released.enumerated() {
                    let url = outputDirectory
                        .appendingPathComponent("loupe-released-\(index).png")
                    try writePNG(snapshot.image, to: url)
                    report.append("松手后 display \(snapshot.displayID) -> \(url.lastPathComponent)")
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

    /// 自检用的小图：彩色块 + 斜线，够看出缩放 / 裁切。
    private static func makeTestImage(width: Int, height: Int) throws -> CGImage {
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

                // 大部分 App 只把滚轮送给「指针下面的窗口」，所以把光标也挪进选区。
                CGEvent(
                    mouseEventSource: CGEventSource(stateID: .hidSystemState),
                    mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left
                )?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(250))

                let variants: [(String, () -> CGEvent?)] = [
                    ("pixel + location（现状）", {
                        Self.scrollEvent(units: .pixel, value: -67, continuous: nil, location: center)
                    }),
                    ("pixel + continuous + 手势 phase", {
                        Self.scrollEvent(
                            units: .pixel, value: -67, continuous: true, location: center,
                            phase: .changed
                        )
                    }),
                    ("line（像真鼠标滚轮）", {
                        Self.scrollEvent(units: .line, value: -3, continuous: false, location: center)
                    }),
                    ("line + 不设 location", {
                        Self.scrollEvent(units: .line, value: -3, continuous: false, location: nil)
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
                    for _ in 0..<3 {
                        variant.1()?.post(tap: .cghidEventTap)
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    let after = try await capturer.capture()
                    let afterBitmap = ScrollStitcher.BitmapData(image: after)
                    let url = outputDirectory.appendingPathComponent("probe-\(index)-after.png")
                    try writePNG(after, to: url)
                    let diff = (beforeBitmap != nil && afterBitmap != nil)
                        ? meanDifference(beforeBitmap!, afterBitmap!) : -1
                    report.append(
                        String(format: "变体 %d（%@）变化=%.2f", index, variant.0, diff)
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
        phase: CGScrollPhase? = nil
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
                        scroller.postScrollStep()
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
                    scroller.postScrollStep(reversed: true)
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
            scroller.postScrollStep()
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

    private static func writePNG(_ image: CGImage, to url: URL) throws {
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

    private static func describe(_ rect: CGRect) -> String {
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
        let imageBounds = CGRect(
            origin: .zero,
            size: CGSize(width: image.width, height: image.height)
        )
        let target = (pixelRect ?? imageBounds).intersection(imageBounds)
        guard !target.isEmpty, let crop = image.cropping(to: target) else { return -1 }

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
        else { return -1 }

        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        return total / Double(width * height)
    }

    private static func finish(_ lines: [String], code: Int32) {
        print("=== Jietu selftest ===")
        for line in lines { print(line) }
        print("======================")
        fflush(stdout)
        exit(code)
    }
}

#endif
