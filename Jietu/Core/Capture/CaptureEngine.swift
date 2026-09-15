import AppKit
import os
@preconcurrency import ScreenCaptureKit

/// 截图引擎。职责边界：
/// - 只负责「拿到干净的画面」，不负责任何 UI
/// - 所有失败路径都必须抛出可诊断的错误（SCK 会静默失败，不能吞掉）
final class CaptureEngine {
    private let logger = Logger(subsystem: "com.liwenjiao.jietu", category: "capture")

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
