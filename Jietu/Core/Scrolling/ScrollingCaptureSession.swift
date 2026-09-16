import CoreGraphics
import Foundation
import os

/// 滚动长图的采样会话：定间隔抓同一块区域，用 `ScrollStitcher` 判断位移并纵向拼接。
///
/// 两种模式：
/// - `.manual`：用户把鼠标放进选区自己滚（合成滚动需要辅助功能权限，这是保守选项）；
/// - `.automatic`：`AutoScroller` 往选区中央发合成滚轮，匀速推进 + 屏蔽用户输入，
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
    /// 采样间隔（秒）。
    var interval: TimeInterval = 0.25
    /// 连续多少拍没有位移就自动结束（自动模式可以短一些：合成滚动没有「人手停顿」）。
    var idleIntervalsToStop = 6
    /// 长图高度上限（像素），超过就收工，避免无限增长。
    var maxPixelHeight = 20_000

    /// 当前长图高度（像素），用于控制条显示进度。
    private(set) var stitchedHeight = 0
    var onProgress: ((Int) -> Void)?

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

    /// 跑完整个采样过程；返回拼接好的长图。没拼出新内容时返回 nil。
    func run() async -> CGImage? {
        let autoScroller = makeAutoScrollerIfNeeded()
        defer {
            autoScroller?.removeInputBlocker()
            scroller = nil
        }

        guard let first = try? await capture() else {
            logger.error("initial region capture failed")
            return nil
        }
        didCaptureAnything = false
        stitchedHeight = first.height
        onProgress?(stitchedHeight)

        var result = first
        var previous = first
        var idleIntervals = 0

        while !isStopped, idleIntervals < idleIntervalsToStop, stitchedHeight < maxPixelHeight {
            // 自动模式：先推一步，再等画面稳定后抓帧。
            autoScroller?.postScrollStep()
            try? await Task.sleep(for: .seconds(interval))
            guard !isStopped else { break }
            guard let frame = try? await capture(), frame.width == previous.width else {
                idleIntervals += 1
                continue
            }

            guard let shift = ScrollStitcher.offset(previous: previous, next: frame) else {
                // 对不上：多半是滚太快跳过了内容，等下一拍再看，连续多次就收工。
                idleIntervals += 1
                continue
            }
            guard shift > 0 else {
                idleIntervals += 1
                continue
            }
            guard let merged = ScrollStitcher.append(base: result, next: frame, shift: shift) else {
                idleIntervals += 1
                continue
            }

            result = merged
            previous = frame
            stitchedHeight = merged.height
            didCaptureAnything = true
            idleIntervals = 0
            onProgress?(stitchedHeight)
        }

        guard didCaptureAnything else {
            logger.notice("no scrolling content captured")
            return nil
        }
        logger.notice("scrolling capture finished at \(self.stitchedHeight)px")
        return result
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
