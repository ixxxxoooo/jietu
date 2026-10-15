import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 滚动长图：真实采样会话与取景框态自检。
///
/// @author ixxxxoooo
extension CaptureSelfTest {
    static func runSessionTest(spec: String, outputDirectory: URL) {
        Task { @MainActor in
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

    static func runChromeTest(spec: String, outputDirectory: URL) {
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

    static func postScrollSteps(_ scroller: AutoScroller, count: Int) {
        for _ in 0..<count {
            scroller.postScrollStep(at: DisplayGeometry.flipY(NSEvent.mouseLocation))
            usleep(120_000)
        }
    }

    /// 自检用：列出本进程在屏幕上的窗口（层级 / 位置 / alpha）。
    static func capturedWindowLines() -> [String] {
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
}

#endif
