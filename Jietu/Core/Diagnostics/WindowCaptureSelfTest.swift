import AppKit
import CoreGraphics

#if DEBUG

/// 窗口截图的自检：枚举屏幕上的窗口，逐个走**真实**的 `CaptureEngine.captureWindow`，
/// 报告每个窗口能不能截、截出来的尺寸对不对，并把成图落盘供目视检查。
///
///   Lucent --selftest-window <输出目录>
///
/// 只读屏幕、不建窗口，可以和正式实例同时在跑。
///
/// @author ixxxxoooo
enum WindowCaptureSelfTest {

    static func run(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            var failures = 0
            do {
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                report.append("屏幕上的窗口 \(windows.count) 个，逐个截前 8 个")
                let engine = CaptureEngine()
                for window in windows.prefix(8) {
                    let frame = window.frameInCGPoints
                    let label =
                        "id=\(window.windowID) \(window.ownerName)/\(window.title) "
                        + "\(Int(frame.width))x\(Int(frame.height))@(\(Int(frame.minX)),\(Int(frame.minY)))"
                    do {
                        let image = try await engine.captureWindow(window)
                        let url = outputDirectory.appendingPathComponent("window-\(window.windowID).png")
                        try CaptureSelfTest.writePNG(image, to: url)
                        report.append("✓ \(label) → \(image.width)x\(image.height) px")
                    } catch {
                        failures += 1
                        report.append("✗ \(label) → \(error.localizedDescription)")
                    }
                }
                if windows.isEmpty {
                    failures += 1
                    report.append("✗ 没有可截的窗口")
                }
            } catch {
                failures += 1
                report.append("error: \(error.localizedDescription)")
            }
            report.append("RESULT: \(failures == 0 ? "PASS" : "FAIL（\(failures) 项失败）")")
            CaptureSelfTest.finish(report, code: failures == 0 ? 0 : 1)
        }
    }
}

#endif
