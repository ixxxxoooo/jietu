import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 滚动长图：每帧成本、合成滚轮写法探针与逐帧拼接自检。
///
/// @author ixxxxoooo
extension CaptureSelfTest {
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
    static func runScrollCostTest() {
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
    static func makeTallPage(width: Int, height: Int) throws -> CGImage {
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

    static func runScrollProbe(spec: String, outputDirectory: URL) {
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

    static func scrollEvent(
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

    static func runFramesTest(spec: String, outputDirectory: URL) {
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
    static func meanDifference(
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
}

#endif
