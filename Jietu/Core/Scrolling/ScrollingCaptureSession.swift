import AppKit
import CoreGraphics
import Foundation
import os

/// 滚动长图的采样会话：定间隔抓同一块区域，用 `ScrollStitcher` 判断位移并纵向拼接。
///
/// 两种模式：
/// - `.manual`：用户把鼠标放进选区自己滚（合成滚动需要辅助功能权限，这是保守选项）；
/// - `.automatic`：`AutoScroller` 往**光标所在点**发合成滚轮，匀速推进；光标移出选区即
///   **暂停**（不滚、也不屏蔽输入），移回来继续——这样用户随时能把鼠标挪去点「完成 / 取消」。
///   任意按键即结束。
///
/// 两种模式都靠「连续若干拍没有位移」判断到底了：连续没有新内容（或用户点完成 / Esc）就收工。
///
/// @author ixxxxoooo
@MainActor
final class ScrollingCaptureSession {
    enum Mode {
        /// 用户自己滚（默认；不需要额外权限）。
        case manual
        /// 合成滚轮自动滚（需要「辅助功能」权限）。
        case automatic
    }

    struct Target {
        let displayID: CGDirectDisplayID
        /// 选区在该显示器上的矩形（点、原点左上）。
        let regionInPoints: CGRect
        /// 同一选区在**全局 cg 坐标**里的矩形（原点主屏左上）——自动滚动要往这里发事件。
        let regionInGlobalCGPoints: CGRect
    }

    private let logger = Logger(subsystem: "com.ixxxxoooo.jietu", category: "scrolling")
    private let engine: CaptureEngine
    private let target: Target

    /// 采样模式。`.automatic` 才会合成滚动事件。
    var mode: Mode = .manual
    /// 采样间隔（秒）。自动模式另有更密的节奏（见 `automaticInterval`）。
    var interval: TimeInterval = 0.25
    /// 自动模式的采样间隔：步子细了，拍子也得跟上，看着才顺。
    var automaticInterval: TimeInterval = 0.12
    /// 连续多少拍没有位移就自动结束（自动模式可以短一些：合成滚动没有「人手停顿」）。
    var idleIntervalsToStop = 6
    /// 还没动起来之前允许的空拍数：手动模式要留给用户「把鼠标挪进选区」的时间，
    /// 否则刚弹完权限提示就开始倒计时，用户还没滚就收工了。
    var startupIntervalsToStop = 24
    /// 长图高度上限（像素），超过就收工，避免无限增长。
    var maxPixelHeight = 20_000
    /// 自动滚动期间的「暂停」回调（光标移出选区）。控制条据此把状态说清楚。
    var onPausedChange: ((Bool) -> Void)?
    /// 右侧预览画布的像素尺寸（由控制条那边按屏幕缩放算好传进来）。
    var previewPixelSize: CGSize = .zero

    /// 当前长图高度（像素），用于控制条显示进度。
    private(set) var stitchedHeight = 0
    var onProgress: ((Int) -> Void)?
    /// 每拼上新内容回一次长图，供右侧实时预览显示。
    var onPreview: ((CGImage) -> Void)?

    private var isStopped = false
    private var didCaptureAnything = false
    /// 自动滚动器（只有 `.automatic` 才创建）。
    private var scroller: AutoScroller?

    init(engine: CaptureEngine, target: Target) {
        self.engine = engine
        self.target = target
    }

    /// 让正在跑的循环在下一拍停下。
    func stop() {
        isStopped = true
    }

    /// 当前允许的空拍上限：还没拼上任何内容时用「起步宽限」，免得用户还没滚就收工。
    private func idleLimit(hasContent: Bool) -> Int {
        hasContent ? idleIntervalsToStop : max(idleIntervalsToStop, startupIntervalsToStop)
    }

    /// 跑完整个采样过程；返回拼接好的长图。没拼出新内容时返回 nil。
    func run() async -> CGImage? {
        let autoScroller = makeAutoScrollerIfNeeded()
        defer {
            autoScroller?.removeInputBlocker()
            scroller = nil
            onPausedChange?(false)
        }

        // 构建长效区域捕获器，避免单帧重复 IPC 查询 shareableContent
        let regionCapturer = try? await engine.makeRegionCapturer(
            displayID: target.displayID,
            regionInPoints: target.regionInPoints
        )

        guard let first = await captureSettledFrame(capturer: regionCapturer) else {
            logger.error("initial region capture failed")
            return nil
        }

        // 自动模式：光标在选区外什么也滚不动（滚轮送给光标下面的窗口），
        // 先把它挪进选区中心一次——「自动」就该点完自己跑，不要用户再手动搬一次鼠标。
        if mode == .automatic, !cursorInsideRegion() {
            let region = target.regionInGlobalCGPoints
            CGWarpMouseCursorPosition(CGPoint(x: region.midX, y: region.midY))
        }

        let stitcher = ScrollStitcher.Session(
            firstFrame: first,
            maxFrames: mode == .automatic ? 240 : 120,
            maxPixelHeight: maxPixelHeight,
            previewPixelSize: previewPixelSize
        )

        didCaptureAnything = false
        stitchedHeight = first.height
        onProgress?(stitchedHeight)
        onPreview?(first)

        // 自动模式：告诉拼接器「每帧大概位移多少像素」，它就能省掉每帧一次的 Vision 配准。
        if mode == .automatic, target.regionInPoints.height > 1 {
            let scale = CGFloat(first.height) / target.regionInPoints.height
            let step = AutoScroller.stepPoints(forHeight: target.regionInPoints.height)
            stitcher.expectedShiftPixels = Int((CGFloat(step) * scale).rounded())
        }

        var idleIntervals = 0
        var isPaused = false

        while !isStopped, idleIntervals < idleLimit(hasContent: didCaptureAnything),
            stitchedHeight < maxPixelHeight
        {
            if mode == .automatic {
                // 光标在选区里才滚。移出去 = 暂停：不滚、放行输入，用户去点控制条。
                let inside = cursorInsideRegion()
                if inside != !isPaused {
                    isPaused = !inside
                    onPausedChange?(isPaused)
                }
                autoScroller?.setActive(inside)
                if inside {
                    autoScroller?.postScrollStep(at: currentCursorCGPoint())
                }
            }

            // 合成滚动要过一拍才落到画面上：抢在它生效前抓，就会把「滚动前」那帧
            // 当成新帧（连续几拍都判「没有新内容」，实测 0.3 秒就误收工）。
            try? await Task.sleep(for: .seconds(mode == .automatic ? automaticInterval : interval))

            // 暂停中不数空拍：用户可能是去点「完成 / 取消」，不该被自动收工抢了先
            // （那会直接把长图交付出去，和「取消」完全是两回事）。
            if mode == .automatic, isPaused {
                continue
            }

            guard !isStopped else { break }

            guard let frame = await captureSettledFrame(capturer: regionCapturer) else {
                idleIntervals += 1
                continue
            }

            let outcome = stitcher.append(frame: frame)
            switch outcome {
            case .appended(let newHeight):
                stitchedHeight = newHeight
                didCaptureAnything = true
                idleIntervals = 0
                onProgress?(stitchedHeight)
                if let preview = stitcher.currentPreviewImage() {
                    onPreview?(preview)
                }

            case .noNewContent:
                idleIntervals += 1

            case .atLimit:
                break
            }

            if case .atLimit = outcome {
                break
            }
        }

        guard didCaptureAnything else {
            logger.notice("no scrolling content captured")
            return nil
        }

        let finalImage = stitcher.finish()
        logger.notice("scrolling capture finished at \(self.stitchedHeight)px")
        return finalImage
    }

    /// 轮询直到两次截取的底层像素数据完全一致（页面平滑动画/重绘沉降完毕）或超时。
    /// 参考 capcap captureSettledFrame 机制，防止抓取平滑滚动途中的模糊中间态。
    private func captureSettledFrame(capturer: CaptureEngine.RegionCapturer?) async -> CGImage? {
        guard let capturer else {
            return try? await capture()
        }

        var previousData: CFData?
        var lastImage: CGImage?
        var waitMs: UInt64 = 15
        let deadline = Date().addingTimeInterval(1.2)

        for _ in 0..<12 {
            guard Date() < deadline, !isStopped else { break }
            guard let image = try? await capturer.capture() else {
                try? await Task.sleep(nanoseconds: 25_000_000)
                continue
            }

            guard let data = image.dataProvider?.data else {
                return image
            }

            if let prev = previousData, CFEqual(prev, data) {
                return image
            }

            previousData = data
            lastImage = image
            try? await Task.sleep(nanoseconds: waitMs * 1_000_000)
            waitMs = min(waitMs * 3 / 2, 70)
        }

        return lastImage
    }

    /// 光标当前所在的全局 cg 坐标（原点主屏左上）。
    private func currentCursorCGPoint() -> CGPoint {
        DisplayGeometry.flipY(NSEvent.mouseLocation)
    }

    #if DEBUG
    /// 自检用：会话内部的选区矩形（全局 cg）。
    var debugRegion: CGRect { target.regionInGlobalCGPoints }
    #endif

    /// 光标是否落在选区里（= 自动滚动该不该滚）。
    ///
    /// 合成滚轮是发给「光标下面的窗口」的，所以光标在选区里才滚得动；移出去就暂停，
    /// 顺手把输入让开——用户随时能把鼠标挪去点控制条上的「完成 / 取消」。
    static func shouldScroll(cursor: CGPoint, region: CGRect) -> Bool {
        region.contains(cursor)
    }

    private func cursorInsideRegion() -> Bool {
        Self.shouldScroll(cursor: currentCursorCGPoint(), region: target.regionInGlobalCGPoints)
    }

    /// 自动模式才建滚动器：往选区中央发合成滚轮，并屏蔽用户在选区里的输入。
    private func makeAutoScrollerIfNeeded() -> AutoScroller? {
        guard mode == .automatic else { return nil }
        guard AccessibilityPermission.isGranted else {
            logger.notice("auto scroll requested without accessibility permission")
            return nil
        }

        let rect = target.regionInGlobalCGPoints
        let scroller = AutoScroller(
            center: CGPoint(x: rect.midX, y: rect.midY),
            blockingRect: rect,
            stepPoints: AutoScroller.stepPoints(forHeight: rect.height)
        )
        scroller.onKeyPressed = { [weak self] in self?.stop() }
        scroller.installInputBlocker()
        self.scroller = scroller
        logger.notice("auto scroll step=\(AutoScroller.stepPoints(forHeight: rect.height))pt")
        return scroller
    }

    private func capture() async throws -> CGImage {
        try await engine.captureRegion(
            displayID: target.displayID,
            regionInPoints: target.regionInPoints
        )
    }
}
