import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 截图引擎与区域坐标系自检。
///
/// @author ixxxxoooo
extension CaptureSelfTest {
    static func runRegionTest(spec: String, outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            do {
                let engine = CaptureEngine()
                let full = try await engine.captureAllDisplays()
                guard !full.isEmpty else { throw CaptureError.noDisplays }
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                let rect = parseRect(spec) ?? CGRect(x: 0, y: 0, width: 400, height: 300)
                report.append("screens=\(NSScreen.screens.count) rect(top-left, points)=\(describe(rect))")

                for snapshot in full {
                    let frame = snapshot.screenFrameInPoints
                    let scale = snapshot.effectiveScale
                    report.append(
                        "display=\(snapshot.displayID) frame=\(describe(frame))"
                            + " scale=\(String(format: "%.2f", scale))"
                    )

                    // 1) SCK 按 sourceRect 直接抓（滚动长图走的就是这条）。
                    let direct = try await engine.captureRegion(
                        displayID: snapshot.displayID, regionInPoints: rect
                    )
                    let directURL = outputDirectory
                        .appendingPathComponent("region-sck-\(snapshot.displayID).png")
                    try writePNG(direct, to: directURL)
                    report.append(
                        "  sck  \(direct.width)x\(direct.height)"
                            + " mean=\(String(format: "%.1f", meanLuminance(direct)))"
                            + " -> \(directURL.lastPathComponent)"
                    )

                    // 2) 整屏抓 → 按同一块区域裁（已知正确的那条路）。
                    let bottomLeft = CGRect(
                        x: rect.minX,
                        y: frame.height - rect.maxY,
                        width: rect.width,
                        height: rect.height
                    )
                    let crop = CaptureOutput.crop(snapshot, toLocalRect: bottomLeft)
                    if let crop {
                        let cropURL = outputDirectory
                            .appendingPathComponent("region-crop-\(snapshot.displayID).png")
                        try writePNG(crop, to: cropURL)
                        report.append(
                            "  crop \(crop.width)x\(crop.height)"
                                + " mean=\(String(format: "%.1f", meanLuminance(crop)))"
                                + " -> \(cropURL.lastPathComponent)"
                        )
                        report.append(
                            "  同尺寸=\(crop.width == direct.width && crop.height == direct.height)"
                                + " 同内容=\(Self.samePixels(crop, direct))"
                        )
                    } else {
                        report.append("  crop 失败（local=\(describe(bottomLeft))）")
                    }
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

    /// 稀疏采样比像素：抓错区域时这里会直接报 false。
    /// 先各自画进同一个 64×64 RGBA 上下文再比，免受行距 / 色彩空间差异干扰。
    static func samePixels(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width > 1, b.width > 1 else { return false }
        let width = 64
        let height = 64
        func raster(_ image: CGImage) -> [UInt8]? {
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard
                let context = CGContext(
                    data: &pixels, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return pixels
        }
        guard let pa = raster(a), let pb = raster(b) else { return false }
        for index in stride(from: 0, to: pa.count, by: 4) {
            if abs(Int(pa[index]) - Int(pb[index])) > 6 { return false }
            if abs(Int(pa[index + 1]) - Int(pb[index + 1])) > 6 { return false }
            if abs(Int(pa[index + 2]) - Int(pb[index + 2])) > 6 { return false }
        }
        return true
    }

    static func runCaptureTest(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            report.append("preflight.screenCapture = \(ScreenCapturePermission.isGranted)")
            report.append("screens.count = \(NSScreen.screens.count)")

            for (index, screen) in NSScreen.screens.enumerated() {
                let displayID = screen.jietu_displayID
                let cgBounds = displayID.map { Self.describe(CGDisplayBounds($0)) } ?? "n/a"
                report.append(
                    "screen[\(index)] id=\(displayID.map(String.init) ?? "nil")"
                        + " appkitFrame=\(Self.describe(screen.frame))"
                        + " cgDisplayBounds=\(cgBounds)"
                        + " backingScale=\(screen.backingScaleFactor)"
                )
            }

            do {
                let snapshots = try await CaptureEngine().captureAllDisplays()
                report.append("captured \(snapshots.count) snapshot(s)")

                try FileManager.default.createDirectory(
                    at: outputDirectory,
                    withIntermediateDirectories: true
                )

                for (index, snapshot) in snapshots.enumerated() {
                    let name = String(format: "display-%d-%u.png", index, snapshot.displayID)
                    let url = outputDirectory.appendingPathComponent(name)
                    try Self.writePNG(snapshot.image, to: url)
                    report.append(
                        "  [\(index)] displayID=\(snapshot.displayID)"
                            + " points=\(Self.describe(snapshot.screenFrameInPoints))"
                            + " pixels=\(Int(snapshot.pixelSize.width))x\(Int(snapshot.pixelSize.height))"
                            + " nominalScale=\(snapshot.nominalScaleFactor)"
                            + " effectiveScale=\(String(format: "%.4f", snapshot.effectiveScale))"
                            + " file=\(url.path)"
                    )
                }
                report.append("RESULT: PASS")
                Self.finish(report, code: 0)
            } catch {
                report.append("error: \(error.localizedDescription)")
                if let captureError = error as? CaptureError {
                    report.append("recovery: \(captureError.recoverySuggestion ?? "-")")
                }
                report.append("RESULT: FAIL")
                Self.finish(report, code: 1)
            }
        }
    }
}

#endif
