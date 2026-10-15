import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 就地标注 / 编辑工具栏自检。
///
/// @author ixxxxoooo
extension CaptureSelfTest {
    /// 就地标注「框里还能再画框」自检。
    ///
    /// 用户报过：画完一个矩形（或椭圆），再想在它**里面**画一个，一按就变成
    /// 「选中并移动外面那个框」，中间根本画不上东西。
    /// 根因：命中判定按**整块矩形**算，而渲染只画了边框（`context.stroke`）。
    ///
    /// 这条自检真画两个框（第二个画在第一个里面），再采样内框的上边：
    /// 有标注色 = 框画出来了；没颜色 = 又被外面那个框吃掉了。
    static func runInlineDrawTest(outputDirectory: URL) {
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

                // 区域截图默认不选工具：框内拖动会平移选区。先选矩形工具，才是在框里画框。
                coordinator.debugSelectTool(.rectangle, displayID: displayID)

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
    static func runInlineScrollTest(outputDirectory: URL) {
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

    static func runEditorTest(outputDirectory: URL, inline: Bool) {
        Task { @MainActor in
            var report: [String] = []
            let model = InlineToolbarModel()
            let probe = InlineMainToolbar(model: model)
            let probeHost = NSHostingView(rootView: probe)
            report.append(
                "InlineToolbar SwiftUI 最小宽=\(Int(probeHost.fittingSize.width.rounded()))"
                    + " 高=\(Int(probeHost.fittingSize.height.rounded()))"
            )
            report.append("RESULT: PASS")
            finish(report, code: 0)
        }
    }

    /// 自检用的「最坏底图」：纯白 + 一圈浅灰描边，专治按钮糊在白底里。
    static func makeWhiteTestImage(width: Int, height: Int) throws -> CGImage {
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
    static func makeTextTestImage(width: Int, height: Int) throws -> CGImage {
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
}

#endif
