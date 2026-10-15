import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 放大镜自检。
///
/// @author ixxxxoooo
extension CaptureSelfTest {
    static func runLoupeTest(spec: String, outputDirectory: URL) {
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
    static func texturedPixel(in image: CGImage) -> CGPoint {
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
    static func verifyLoupeSampling(
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
    static func hexDelta(_ lhs: String, _ rhs: String) -> Int {
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

    static func activeLoupeState(
        _ coordinator: OverlayCoordinator
    ) -> (displayID: CGDirectDisplayID, state: OverlayCanvasView.DebugLoupeState)? {
        // 闭包返回类型要写全（含元组标签）：只靠返回值推断时，Xcode 26 的编译器会
        // 报 "generic parameter 'ElementOfResult' could not be inferred"。
        coordinator.debugSelections.compactMap {
            entry -> (displayID: CGDirectDisplayID, state: OverlayCanvasView.DebugLoupeState)? in
            guard let state = coordinator.debugLoupeState(displayID: entry.displayID)
            else { return nil }
            return (displayID: entry.displayID, state: state)
        }.first
    }
}

#endif
