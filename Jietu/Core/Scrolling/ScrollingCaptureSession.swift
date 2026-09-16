import CoreGraphics
import Foundation
import os

/// 滚动长图的采样会话：定间隔抓同一块区域，用 `ScrollStitcher` 判断位移并纵向拼接。
///
/// 不做任何「自动滚动」——合成滚动事件需要「辅助功能」权限，而 Jietu 目前只申请
/// 屏幕录制权限。所以这里由用户手动滚动内容，会话负责连续采样：
/// 连续若干拍没有位移（或用户点了完成 / 按了 Esc）就收工。
///
/// @author ixxxxoooo
@MainActor
final class ScrollingCaptureSession {
    struct Target {
        let displayID: CGDirectDisplayID
        /// 选区在该显示器上的矩形（点、原点左上）。
        let regionInPoints: CGRect
    }

    private let logger = Logger(subsystem: "com.ixxxxoooo.jietu", category: "scrolling")
    private let engine: CaptureEngine
    private let target: Target

    /// 采样间隔（秒）。
    var interval: TimeInterval = 0.25
    /// 连续多少拍没有位移就自动结束。
    var idleIntervalsToStop = 6
    /// 长图高度上限（像素），超过就收工，避免无限增长。
    var maxPixelHeight = 20_000

    /// 当前长图高度（像素），用于控制条显示进度。
    private(set) var stitchedHeight = 0
    var onProgress: ((Int) -> Void)?

    private var isStopped = false
    private var didCaptureAnything = false

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

    private func capture() async throws -> CGImage {
        try await engine.captureRegion(
            displayID: target.displayID,
            regionInPoints: target.regionInPoints
        )
    }
}
