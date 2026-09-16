import AppKit
import os
@preconcurrency import ScreenCaptureKit

/// 截图引擎。职责边界：
/// - 只负责「拿到干净的画面」，不负责任何 UI
/// - 所有失败路径都必须抛出可诊断的错误（SCK 会静默失败，不能吞掉）
final class CaptureEngine {
    private let logger = Logger(subsystem: "com.ixxxxoooo.jietu", category: "capture")

    /// 冻结全部显示器。
    ///
    /// 先冻结再弹遮罩窗是必须的：否则遮罩窗自己会被拍进画面，
    /// 且后续的窗口吸附也需要一个稳定的画面来做命中判定。
    func captureAllDisplays(excludingOwnApplication: Bool = true) async throws -> [DisplaySnapshot] {
        guard ScreenCapturePermission.isGranted else {
            throw CaptureError.permissionDenied
        }

        let content = try await shareableContent()
        let ownApplications: [SCRunningApplication] = excludingOwnApplication
            ? content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            : []

        var snapshots: [DisplaySnapshot] = []
        var failures: [Error] = []

        for screen in NSScreen.screens {
            guard let displayID = screen.jietu_displayID else { continue }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                failures.append(CaptureError.displayNotShareable(displayID))
                continue
            }

            do {
                snapshots.append(
                    try await capture(
                        screen: screen,
                        display: display,
                        excluding: ownApplications
                    )
                )
            } catch {
                logger.error("display \(displayID) capture failed: \(error.localizedDescription)")
                failures.append(error)
            }
        }

        if snapshots.isEmpty {
            throw failures.first ?? CaptureError.noDisplays
        }
        if !failures.isEmpty {
            logger.warning("\(failures.count) display(s) failed, \(snapshots.count) succeeded")
        }
        return snapshots
    }

    /// 捕获单个窗口（窗口截图模式）。
    ///
    /// 用 `SCContentFilter(desktopIndependentWindow:)` 直接按窗口抓，
    /// 不需要弹遮罩，也不会把遮挡它的窗口拍进去。
    func captureWindow(_ window: WindowInfo) async throws -> CGImage {
        guard ScreenCapturePermission.isGranted else {
            throw CaptureError.permissionDenied
        }

        let content = try await shareableContent()
        guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
            throw CaptureError.windowNotCapturable(window.windowID)
        }

        // 窗口坐标是 CG（原点主屏左上），先翻成 AppKit 才能匹配 NSScreen。
        let center = CGPoint(
            x: window.frameInCGPoints.midX,
            y: DisplayGeometry.referenceHeight - window.frameInCGPoints.midY
        )
        let scale = NSScreen.screens.first { $0.frame.contains(center) }?.backingScaleFactor ?? 2

        let configuration = SCScreenshotConfiguration()
        configuration.width = max(1, Int((window.frameInCGPoints.width * scale).rounded()))
        configuration.height = max(1, Int((window.frameInCGPoints.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter,
            configuration: configuration
        )
        guard let image = output.sdrImage ?? output.hdrImage else {
            throw CaptureError.windowNotCapturable(window.windowID)
        }
        return image
    }

    /// 用于高频采样的区域捕获器（如滚动长图）：会话开始前构建一次 Filter 与 Configuration，
    /// 后续每拍无需反复 IPC 查询 SCShareableContent。
    final class RegionCapturer {
        private let filter: SCContentFilter
        private let configuration: SCScreenshotConfiguration
        private let displayID: CGDirectDisplayID

        fileprivate init(
            filter: SCContentFilter,
            configuration: SCScreenshotConfiguration,
            displayID: CGDirectDisplayID
        ) {
            self.filter = filter
            self.configuration = configuration
            self.displayID = displayID
        }

        func capture() async throws -> CGImage {
            let output = try await SCScreenshotManager.captureScreenshot(
                contentFilter: filter,
                configuration: configuration
            )
            guard let image = output.sdrImage ?? output.hdrImage else {
                throw CaptureError.emptyImage(displayID)
            }
            return image
        }
    }

    /// 构建一个针对特定选区的长效捕获器（如滚动长图采样循环使用）。
    func makeRegionCapturer(
        displayID: CGDirectDisplayID,
        regionInPoints: CGRect,
        excludingOwnApplication: Bool = true
    ) async throws -> RegionCapturer {
        guard ScreenCapturePermission.isGranted else {
            throw CaptureError.permissionDenied
        }

        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotShareable(displayID)
        }
        let scale = NSScreen.screens.first { $0.jietu_displayID == displayID }?
            .backingScaleFactor ?? 2

        let region = regionInPoints.integral
        guard region.width >= 1, region.height >= 1 else {
            throw CaptureError.emptyRegion
        }

        let configuration = SCScreenshotConfiguration()
        configuration.sourceRect = region
        configuration.width = max(1, Int((region.width * scale).rounded()))
        configuration.height = max(1, Int((region.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr

        let ownApplications = excludingOwnApplication
            ? content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            : []
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        return RegionCapturer(filter: filter, configuration: configuration, displayID: displayID)
    }

    /// 抓某个显示器上的一块区域（点坐标、原点左上，相对该显示器）。
    ///
    /// 滚动长图靠它反复抓同一块区域：只取需要的那块，比整屏抓再裁省一个数量级的带宽。
    /// 默认把本 App 排除在画面外，所以浮在选区上的控制条不会被拍进去。
    func captureRegion(
        displayID: CGDirectDisplayID,
        regionInPoints: CGRect,
        excludingOwnApplication: Bool = true
    ) async throws -> CGImage {
        let capturer = try await makeRegionCapturer(
            displayID: displayID,
            regionInPoints: regionInPoints,
            excludingOwnApplication: excludingOwnApplication
        )
        return try await capturer.capture()
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            // onScreenWindowsOnly: false —— 否则全屏空间里的窗口拿不到。
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            logger.error("SCShareableContent failed: \(error.localizedDescription)")
            throw CaptureError.noShareableContent(error.localizedDescription)
        }
    }

    private func capture(
        screen: NSScreen,
        display: SCDisplay,
        excluding applications: [SCRunningApplication]
    ) async throws -> DisplaySnapshot {
        let scale = screen.backingScaleFactor
        let configuration = SCScreenshotConfiguration()
        configuration.width = max(1, Int((screen.frame.width * scale).rounded()))
        configuration.height = max(1, Int((screen.frame.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr

        let filter = SCContentFilter(
            display: display,
            excludingApplications: applications,
            exceptingWindows: []
        )

        let output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter,
            configuration: configuration
        )

        guard let image = output.sdrImage ?? output.hdrImage else {
            throw CaptureError.emptyImage(display.displayID)
        }

        return DisplaySnapshot(
            displayID: display.displayID,
            screenFrameInPoints: screen.frame,
            nominalScaleFactor: scale,
            image: image
        )
    }
}
