import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 钉图按钮对比度自检。
///
/// @author ixxxxoooo
extension CaptureSelfTest {
    static func runPinTest(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            do {
                let screen = NSScreen.main ?? NSScreen.screens[0]
                let visible = screen.visibleFrame
                let scale = max(1, screen.backingScaleFactor)
                let image = try makeWhiteTestImage(width: 520, height: 340)
                PinWindowController.pin(image: image, on: screen)
                try? await Task.sleep(for: .milliseconds(700))

                // 钉图窗口居中、按原始大小显示（和 PinWindowController 的默认摆放一致）。
                let size = CGSize(
                    width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale
                )
                let frame = NSRect(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ).integral
                report.append(
                    "pin frame=\(describe(frame)) (白底图 \(image.width)x\(image.height)px)"
                )

                // 鼠标挪进钉图窗口，浮动按钮才会出现（用户可能同时在动鼠标，多试两次）。
                let inside = CGPoint(
                    x: frame.midX, y: DisplayGeometry.referenceHeight - frame.midY
                )
                let closeCenter = CGPoint(x: frame.maxX - 22, y: frame.maxY - 22)
                var snapshot: DisplaySnapshot?
                for attempt in 1...3 {
                    // 先挪到窗口外面再进来：光标本来就在原地的话不产生移动，触发不了 mouseEntered。
                    postMouse(.mouseMoved, at: CGPoint(x: frame.minX - 60, y: inside.y))
                    try? await Task.sleep(for: .milliseconds(150))
                    postMouse(.mouseMoved, at: inside)
                    try? await Task.sleep(for: .milliseconds(500))
                    let shots = try await CaptureEngine().captureAllDisplays(
                        excludingOwnApplication: false
                    )
                    let shot = shots.first { $0.displayID == NSScreen.main?.jietu_displayID }
                        ?? shots.first
                    snapshot = shot
                    let probe = shot.map { luminance(in: $0, at: closeCenter, size: 6) } ?? 1
                    if probe < 0.9 {
                        break
                    }
                    report.append(
                        String(format: "第 %d 次注入后按钮还是没出来（探到 %.3f），重试", attempt, probe)
                    )
                }

                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )
                guard let snapshot else { throw CaptureError.noDisplays }
                let url = outputDirectory.appendingPathComponent("pin-white.png")
                try writePNG(snapshot.image, to: url)
                report.append("截图 -> \(url.path)")

                // 四个角按钮的中心（各留 8pt 边距；圆盘直径 28）；
                // 各取两块：圆盘边缘（不含图标）与圆心（图标）——前者代表按钮自身的亮度。
                let buttonCenters = [
                    ("右上关闭", closeCenter),
                    ("右下识别文本", CGPoint(x: frame.maxX - 22, y: frame.minY + 22)),
                    ("左上编辑", CGPoint(x: frame.minX + 22, y: frame.maxY - 22)),
                ]
                for (name, center) in buttonCenters {
                    let disc = luminance(in: snapshot, at: center, size: 6)
                    let edge = luminance(
                        in: snapshot, at: CGPoint(x: center.x, y: center.y - 9), size: 6
                    )
                    report.append(
                        String(format: "%@ 圆心=%.3f 圆盘=%.3f（白底=1.000）", name, disc, edge)
                    )
                }

                // 点一下右下角的「识别文本」按钮：开启后应当变成 **macOS 那种蓝底实心圆**。
                // 探针用 AppKit 坐标，注入的鼠标事件得翻成 CG 的 Y 向下坐标。
                let liveTextCenter = CGPoint(x: frame.maxX - 22, y: frame.minY + 22)
                let liveTextClick = CGPoint(
                    x: liveTextCenter.x, y: DisplayGeometry.referenceHeight - liveTextCenter.y
                )
                postMouse(.mouseMoved, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(250))
                postMouse(.leftMouseDown, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(80))
                postMouse(.leftMouseUp, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(900))

                let litShots = try await CaptureEngine().captureAllDisplays(
                    excludingOwnApplication: false
                )
                guard
                    let lit = litShots.first(where: { $0.displayID == snapshot.displayID })
                        ?? litShots.first
                else { throw CaptureError.noDisplays }
                let litURL = outputDirectory.appendingPathComponent("pin-livetext.png")
                try writePNG(lit.image, to: litURL)
                report.append("开启识别文本后截图 -> \(litURL.path)")

                // 按钮圆盘：点亮前后都取同一块，比「蓝偏移」（B−R）——蓝底白图标比绿勾更好认，
                // 未点亮是白玻璃上的黑图标（B−R≈0），点亮后是整块品牌蓝（B−R 明显为正）。
                let offBlue = blueBias(in: snapshot, at: liveTextCenter, size: 6)
                let litBlue = blueBias(in: lit, at: liveTextCenter, size: 6)
                let discBlue = blueBias(in: lit, at: CGPoint(x: frame.maxX - 22, y: frame.minY + 15), size: 4)
                let turnedBlue = litBlue > 0.2 && litBlue - offBlue > 0.2
                report.append(
                    String(format: "按钮中心蓝偏移：点亮前 %.3f → 点亮后 %.3f（圆盘边缘 %.3f）→ %@",
                           offBlue, litBlue, discBlue, turnedBlue ? "已是蓝底实心" : "**没变蓝**")
                )

                // 再点一次「识别文本」关掉它，免得覆盖层挡住后面的按钮。
                postMouse(.mouseMoved, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(200))
                postMouse(.leftMouseDown, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(80))
                postMouse(.leftMouseUp, at: liveTextClick)
                try? await Task.sleep(for: .milliseconds(400))

                // 关闭按钮的响应：从注入「按下」到窗口真的从屏幕上消失。
                // 用户感知的就是这一段（按下动画 + 抬起后关窗）。
                let closeClick = CGPoint(
                    x: closeCenter.x, y: DisplayGeometry.referenceHeight - closeCenter.y
                )
                postMouse(.mouseMoved, at: closeClick)
                try? await Task.sleep(for: .milliseconds(250))
                let pressAt = CFAbsoluteTimeGetCurrent()
                postMouse(.leftMouseDown, at: closeClick)
                try? await Task.sleep(for: .milliseconds(60))  // 普通点击的按住时长
                let releaseAt = CFAbsoluteTimeGetCurrent()
                postMouse(.leftMouseUp, at: closeClick)

                var goneAt: CFAbsoluteTime?
                while CFAbsoluteTimeGetCurrent() - pressAt < 3 {
                    let stillVisible = NSApp.windows.contains { $0 is PinPanel && $0.isVisible }
                    if !stillVisible {
                        goneAt = CFAbsoluteTimeGetCurrent()
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                if let goneAt {
                    report.append(
                        String(
                            format: "关闭按钮：按下→消失 %.0f ms（其中按住 60 ms），抬起→消失 %.0f ms",
                            (goneAt - pressAt) * 1000, (goneAt - releaseAt) * 1000
                        )
                    )
                } else {
                    report.append("关闭按钮：3 秒内窗口**没关掉**")
                }

                // 用一张**有字**的图来验「编辑」。
                // 上面那张已经关掉了，这张仍钉在屏幕正中。
                let textImage = try makeTextTestImage(width: 520, height: 240)
                PinWindowController.pin(image: textImage, on: screen)
                try? await Task.sleep(for: .milliseconds(700))
                let textCard = CGSize(
                    width: CGFloat(textImage.width) / scale, height: CGFloat(textImage.height) / scale
                )
                let textFrame = NSRect(
                    x: visible.midX - textCard.width / 2,
                    y: visible.midY - textCard.height / 2,
                    width: textCard.width,
                    height: textCard.height
                )

                // 左上角「编辑」：点一下应当把「图 + 钉图位置」交出去，并把自己收掉
                // （回到标注编辑器那条路）。就用手上这张有字的图来验。
                var editHandoff: (imageSize: CGSize, rect: CGRect)?
                PinWindowController.onRequestEdit = { edited, rect in
                    editHandoff = (CGSize(width: edited.width, height: edited.height), rect)
                }
                let editCenter = CGPoint(x: textFrame.minX + 22, y: textFrame.maxY - 22)
                let editClick = CGPoint(
                    x: editCenter.x, y: DisplayGeometry.referenceHeight - editCenter.y
                )
                postMouse(.mouseMoved, at: editClick)
                try? await Task.sleep(for: .milliseconds(250))
                let editPressAt = CFAbsoluteTimeGetCurrent()
                postMouse(.leftMouseDown, at: editClick)
                try? await Task.sleep(for: .milliseconds(80))
                postMouse(.leftMouseUp, at: editClick)
                var editMs: Double?
                while CFAbsoluteTimeGetCurrent() - editPressAt < 2 {
                    if editHandoff != nil {
                        editMs = (CFAbsoluteTimeGetCurrent() - editPressAt) * 1000
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                let pinGone = !NSApp.windows.contains { $0 is PinPanel && $0.isVisible }
                report.append(
                    String(
                        format: "左上角「编辑」→ %@ %@，交出的图=%@，钉图已收掉=%@",
                        editHandoff == nil ? "**没触发**" : "已触发",
                        describe(milliseconds: editMs),
                        editHandoff.map { "\(Int($0.imageSize.width))×\(Int($0.imageSize.height))" } ?? "—",
                        pinGone ? "是" : "**否**"
                    )
                )
                let editOK = editHandoff?.imageSize
                    == CGSize(width: textImage.width, height: textImage.height)
                    && pinGone

                let passed = turnedBlue && editOK
                report.append("RESULT: \(passed ? "PASS" : "FAIL")")
                finish(report, code: passed ? 0 : 1)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }

    /// 指定屏幕点（AppKit 全局坐标）附近一块的像素平均亮度。
    static func luminance(
        in snapshot: DisplaySnapshot, at center: CGPoint, size: CGFloat
    ) -> Double {
        let scale = snapshot.effectiveScale
        let local = CGPoint(
            x: center.x - snapshot.screenFrameInPoints.minX,
            y: center.y - snapshot.screenFrameInPoints.minY
        )
        let rect = CGRect(
            x: (local.x - size / 2) * scale,
            y: (snapshot.screenFrameInPoints.height - local.y - size / 2) * scale,
            width: size * scale,
            height: size * scale
        )
        return meanLuminance(snapshot.image, pixelRect: rect)
    }
}

#endif
