import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 遮罩、吸附预览与引导窗自检。
///
/// @author ixxxxoooo
extension CaptureSelfTest {
    /// 吸附预览「按下即收」自检。
    ///
    /// 用户报的现象：鼠标停在一个窗口上，那圈绿色吸附描边好好的；**一按下准备框选**，
    /// 描边却还赖在窗口上不动（一直拖到选区成型才不见）。视觉焦点应该当场跟到
    /// 鼠标开始操作的地方去。
    ///
    /// 这条自检把四段都量一遍：悬停出现 → 按下消失（毫秒）→ 拖动全程不回来 → 松手后该回来就回来。
    static func runOverlayPressTest(outputDirectory: URL) {
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
                        x: start.x + CGFloat(step) * 1.2, y: start.y + CGFloat(step) * 0.8
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

                // 4. 拖过 3pt 阈值但不到最小选区（6pt）就松手：选区被丢弃，回到「还没选区」，
                //    描边该当场回来。（非原地模式下，拖出够大的选区一松手就直接落地、遮罩收掉，
                //    所以这里刻意只拖一点点。）
                let backAt = CFAbsoluteTimeGetCurrent()
                postMouse(.leftMouseUp, at: CGPoint(x: start.x + 4.8, y: start.y + 3.2))
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

    static func runOverlayTest(duration: Double, outputDirectory: URL) {
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

    /// 遮罩测试期间必须有人持有 coordinator，否则窗口会被立刻释放。
    static var retainedCoordinator: OverlayCoordinator?
    static var retainedOnboarding: OnboardingWindowController?

    static func runOnboardingTest(duration: Double) {
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
}

#endif
