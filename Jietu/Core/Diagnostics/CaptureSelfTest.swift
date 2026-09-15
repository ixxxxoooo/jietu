import AppKit
import ImageIO
import UniformTypeIdentifiers

#if DEBUG

/// 命令行自检入口，只在 Debug 构建里编译。
///
/// 存在的原因：屏幕捕获的失败模式大多发生在「UI 之前」（权限、坐标、缩放），
/// 靠肉眼点界面很难定位。这两个开关让捕获链路可以无人值守地跑通并留下证据。
///
///   Jietu --selftest-capture <输出目录>     冻结全部屏幕 → 落 PNG → 打印报告 → 退出
///   Jietu --selftest-overlay <持续秒数>     冻结全部屏幕 → 弹出遮罩 → 保持 N 秒 → 退出
enum CaptureSelfTest {
    @MainActor
    static func handleCommandLineIfNeeded() -> Bool {
        let arguments = CommandLine.arguments

        guard let flagIndex = arguments.firstIndex(where: { $0.hasPrefix("--selftest") }) else {
            return false
        }
        // 自检经常被 kill，行缓冲会让日志全部丢失。
        setvbuf(stdout, nil, _IONBF, 0)
        let flag = arguments[flagIndex]
        let value = arguments.count > flagIndex + 1 ? arguments[flagIndex + 1] : nil

        switch flag {
        case "--selftest-capture":
            let directory = URL(
                fileURLWithPath: value ?? NSTemporaryDirectory(),
                isDirectory: true
            )
            runCaptureTest(outputDirectory: directory)
            return true

        case "--selftest-overlay":
            let seconds = Double(value ?? "10") ?? 10
            let directory = arguments.count > flagIndex + 2
                ? URL(fileURLWithPath: arguments[flagIndex + 2], isDirectory: true)
                : URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            runOverlayTest(duration: seconds, outputDirectory: directory)
            return true

        case "--selftest-onboarding":
            runOnboardingTest(duration: Double(value ?? "8") ?? 8)
            return true

        default:
            return false
        }
    }

    private static func runCaptureTest(outputDirectory: URL) {
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

    private static func runOverlayTest(duration: Double, outputDirectory: URL) {
        Task { @MainActor in
            do {
                let snapshots = try await CaptureEngine().captureAllDisplays()
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                print("windows on screen = \(windows.count)")
                for window in windows.prefix(5) {
                    print(
                        "  win=\(window.windowID) owner=\"\(window.ownerName)\""
                            + " title=\"\(window.title)\" cgFrame=\(describe(window.frameInCGPoints))"
                    )
                }

                let coordinator = OverlayCoordinator()
                self.retainedCoordinator = coordinator

                // 基线：不含自身窗口，等于「用户看到的原始画面」。
                let baseline = try await CaptureEngine().captureAllDisplays()

                coordinator.onFinish = { outcome in
                    // 自检里不退出，否则会掩盖「谁把遮罩关掉了」这个问题。
                    switch outcome {
                    case .cancelled:
                        print("overlay outcome=cancelled")
                    case .captured(let image, let displayID, _, _):
                        print("overlay outcome=captured \(image.width)x\(image.height) display=\(displayID)")
                        try? FileManager.default.createDirectory(
                            at: outputDirectory,
                            withIntermediateDirectories: true
                        )
                        let url = outputDirectory.appendingPathComponent("cropped-\(displayID).png")
                        try? Self.writePNG(image, to: url)
                        print("  cropped -> \(url.path)")
                    }
                }
                coordinator.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: false
                )
                print("overlay presented for \(snapshots.count) display(s), holding \(duration)s")

                try? await Task.sleep(for: .milliseconds(700))
                dumpOwnWindows(label: "after 0.7s")

                // 留出时间给外部工具注入鼠标拖拽，再自拍一张，
                // 用来目视检查选区边框 / handle / 尺寸标签 / 放大镜。
                try? await Task.sleep(for: .milliseconds(1500))
                print("--- self-capture with overlay ---")
                let withOverlay = (try? await CaptureEngine()
                    .captureAllDisplays(excludingOwnApplication: false)) ?? []
                try? FileManager.default.createDirectory(
                    at: outputDirectory,
                    withIntermediateDirectories: true
                )
                for (index, snapshot) in withOverlay.enumerated() {
                    let url = outputDirectory
                        .appendingPathComponent("overlay-self-\(index).png")
                    try? Self.writePNG(snapshot.image, to: url)
                    print("  overlay-self[\(index)] -> \(url.path)")
                }

                // 受控验证压暗层：同一批像素，比较「遮罩后」与「基线」的亮度比。
                // 选区内部应≈1.0（不压暗），外部应≈0.55（45% 黑）。
                // 无选区但吸附到满屏窗口时，整个画面都该是≈1.0。
                for entry in coordinator.debugSelections {
                    guard let baseImage = baseline.first(where: { $0.displayID == entry.displayID })?.image,
                        let overlayImage = withOverlay.first(where: { $0.displayID == entry.displayID })?.image
                    else { continue }

                    let centerRect = CGRect(
                        x: overlayImage.width / 4,
                        y: overlayImage.height / 2,
                        width: 400,
                        height: 200
                    )
                    Self.reportDim(
                        "center ",
                        baseline: baseImage,
                        overlay: overlayImage,
                        rect: centerRect
                    )

                    guard let localRect = entry.localRect,
                        let snapshot = snapshots.first(where: { $0.displayID == entry.displayID })
                    else {
                        print("  display \(entry.displayID): 无选区（只报了 center）")
                        continue
                    }
                    let pixelRect = Self.pixelRect(forLocalRect: localRect, snapshot: snapshot)
                    let stripWidth = max(40, min(240, pixelRect.width * 0.35))
                    let outsideRect = CGRect(
                        x: pixelRect.midX - stripWidth / 2,
                        y: max(0, pixelRect.minY - 70),
                        width: stripWidth,
                        height: 60
                    )
                    print("  display \(entry.displayID) selection=\(describe(localRect))")
                    Self.reportDim("inside ", baseline: baseImage, overlay: overlayImage, rect: pixelRect)
                    Self.reportDim("outside", baseline: baseImage, overlay: overlayImage, rect: outsideRect)
                }

                try? await Task.sleep(for: .seconds(duration))
                coordinator.cancel()
                Self.finish(["overlay held \(duration)s then dismissed", "RESULT: PASS"], code: 0)
            } catch {
                Self.finish(["error: \(error.localizedDescription)", "RESULT: FAIL"], code: 1)
            }
        }
    }

    /// 直接向 WindowServer 查询自己的窗口是否真的在屏幕上。
    private static func dumpOwnWindows(label: String) {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let own = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        print("--- \(label): \(own.count) own window(s) on screen ---")
        for window in own {
            let number = window[kCGWindowNumber as String] as? Int ?? -1
            let layer = window[kCGWindowLayer as String] as? Int ?? -999
            let alpha = window[kCGWindowAlpha as String] as? Double ?? -1
            let sharing = window[kCGWindowSharingState as String] as? Int ?? -1
            let name = window[kCGWindowName as String] as? String ?? ""
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            print(
                "  win=\(number) layer=\(layer) alpha=\(alpha) sharingState=\(sharing)"
                    + " name=\"\(name)\" bounds=\(bounds)"
            )
        }
    }

    /// 遮罩测试期间必须有人持有 coordinator，否则窗口会被立刻释放。
    private static var retainedCoordinator: OverlayCoordinator?
    private static var retainedOnboarding: OnboardingWindowController?

    private static func runOnboardingTest(duration: Double) {
        Task { @MainActor in
            let controller = OnboardingWindowController()
            self.retainedOnboarding = controller
            controller.present()
            print("onboarding presented, permissionGranted=\(ScreenCapturePermission.isGranted)")
            print("policy=\(NSApp.activationPolicy().rawValue) isActive=\(NSApp.isActive)")

            try? await Task.sleep(for: .milliseconds(800))
            let windows = NSApp.windows
            print("NSApp.windows.count=\(windows.count)")
            for window in windows {
                print(
                    "  title=\(window.title) visible=\(window.isVisible)"
                        + " frame=\(Self.describe(window.frame))"
                        + " alpha=\(window.alphaValue) level=\(window.level.rawValue)"
                        + " class=\(type(of: window))"
                )
            }
            dumpOwnWindows(label: "onboarding")

            // 外部 `screencapture` 抓不到本 App 的窗口，只能自拍取证。
            print("--- self-capture with own windows included ---")
            let snapshots = (try? await CaptureEngine()
                .captureAllDisplays(excludingOwnApplication: false)) ?? []
            for (index, snapshot) in snapshots.enumerated() {
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("jietu-onboarding-self-\(index).png")
                try? Self.writePNG(snapshot.image, to: url)
                print("  self-capture[\(index)] -> \(url.path)")
            }

            try? await Task.sleep(for: .seconds(duration))
            Self.finish(["onboarding held \(duration)s", "RESULT: PASS"], code: 0)
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw CaptureError.emptyImage(0)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.emptyImage(0)
        }
    }

    private static func describe(_ rect: CGRect) -> String {
        String(
            format: "(%.0f,%.0f %.0fx%.0f)",
            rect.origin.x, rect.origin.y, rect.width, rect.height
        )
    }

    /// 受控对比：同一批像素在「基线」与「遮罩后」两张图里的亮度比。
    private static func reportDim(
        _ label: String,
        baseline: CGImage,
        overlay: CGImage,
        rect: CGRect
    ) {
        guard !rect.isEmpty else {
            print("    \(label): 采样区为空，跳过")
            return
        }
        let base = meanLuminance(baseline, pixelRect: rect)
        let over = meanLuminance(overlay, pixelRect: rect)
        let ratio = base > 0.0001 ? over / base : 0
        print(
            String(
                format: "    %@ baseline=%.4f overlay=%.4f ratio=%.3f",
                label, base, over, ratio
            )
        )
    }

    /// local（原点左下、point）→ 图像像素矩形（原点左上）。
    private static func pixelRect(forLocalRect rect: CGRect, snapshot: DisplaySnapshot) -> CGRect {
        let scale = snapshot.effectiveScale
        return CGRect(
            x: rect.minX * scale,
            y: (snapshot.screenFrameInPoints.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        .integral
        .intersection(CGRect(origin: .zero, size: snapshot.pixelSize))
    }

    /// 指定像素区域的平均亮度。`cropping` 与调用方都用「原点左上」的像素坐标，
    /// 所以这里不需要再做 Y 翻转。
    private static func meanLuminance(_ image: CGImage, pixelRect: CGRect? = nil) -> Double {
        let imageBounds = CGRect(
            origin: .zero,
            size: CGSize(width: image.width, height: image.height)
        )
        let target = (pixelRect ?? imageBounds).intersection(imageBounds)
        guard !target.isEmpty, let crop = image.cropping(to: target) else { return -1 }

        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return -1 }

        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        return total / Double(width * height)
    }

    private static func finish(_ lines: [String], code: Int32) {
        print("=== Jietu selftest ===")
        for line in lines { print(line) }
        print("======================")
        fflush(stdout)
        exit(code)
    }
}

#endif
