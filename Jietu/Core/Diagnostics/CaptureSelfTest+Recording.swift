import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 录屏自检：真录一段（含暂停），读回成片校验。
///
/// @author ixxxxoooo
extension CaptureSelfTest {
    /// 录屏自检：同一段画面**录两次**（一次中间暂停、一次不暂停），再用 AVFoundation 读回成片比时长。
    ///
    /// 为什么要比而不是绝对值：SCK 首帧来得有早有晚（静止画面只在变化时出帧），
    /// 单看一次录制的时长会把「首帧晚到」算进去。两次录制的环境一样，
    /// 差值就是「暂停那一段有没有被抽掉」+「暂停后有没有继续录」：
    /// - 差值 ≈ 第二段的有效时长（1.4s）→ 正确；
    /// - 差值 ≈ 暂停时长 + 第二段（2.9s）→ 暂停被算进成片了（bug）。
    static func runRecordTest(outputDirectory: URL) {
        Task { @MainActor in
            var report: [String] = []
            var budgets: [(label: String, milliseconds: Double?, limit: Double)] = []
            do {
                guard let screen = NSScreen.main, let displayID = screen.jietu_displayID
                else { throw CaptureError.noDisplays }
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true
                )

                // 显示器 local 坐标（原点左上）：屏幕中上部一块，避开菜单栏。
                let region = CGRect(x: 240, y: 200, width: 560, height: 360)
                let scale = screen.backingScaleFactor
                report.append(
                    "区域 \(describe(region)) 缩放 \(scale)x → 期望像素 "
                        + "\(Int(region.width * scale))×\(Int(region.height * scale))"
                )

                let engineOptions = RecordingEngine.Options(fps: 30, capturesSystemAudio: false)

                /// 录制期间持续在选区里挪光标：SCK 只在画面有变化时出帧。
                @MainActor func wiggle(seconds: Double) async {
                    let deadline = CFAbsoluteTimeGetCurrent() + seconds
                    var index = 0
                    while CFAbsoluteTimeGetCurrent() < deadline {
                        let t = CGFloat(index) * 0.35
                        postMouse(
                            .mouseMoved,
                            at: CGPoint(
                                x: region.midX + cos(t) * region.width * 0.32,
                                y: region.midY + sin(t) * region.height * 0.32
                            )
                        )
                        index += 1
                        try? await Task.sleep(for: .milliseconds(70))
                    }
                }

                /// 录一段（`pauseSeconds > 0` 时在中间暂停一下），返回成片时长。
                @MainActor func record(phase: Double, pauseSeconds: Double, name: String) async -> (
                    duration: Double, url: URL?, error: Error?
                ) {
                    let engine = RecordingEngine()
                    var finished: URL?
                    var failure: Error?
                    var ticks = 0
                    engine.onTick = { _ in ticks += 1 }
                    engine.onFinish = { finished = $0 }
                    engine.onFail = { failure = $0 }
                    do {
                        try await engine.start(
                            displayID: displayID,
                            regionInPoints: region,
                            options: engineOptions,
                            excludingWindowNumbers: []
                        )
                    } catch {
                        return (-1, nil, error)
                    }
                    await wiggle(seconds: phase)
                    if pauseSeconds > 0 {
                        engine.pause()
                        try? await Task.sleep(for: .milliseconds(Int(pauseSeconds * 1000)))
                        engine.resume()
                        await wiggle(seconds: phase)
                    }
                    await engine.stop()
                    report.append("  \(name)：tick \(ticks) 次")
                    guard let url = finished else { return (-1, nil, failure) }
                    let saved = outputDirectory.appendingPathComponent("\(name).mp4")
                    try? FileManager.default.removeItem(at: saved)
                    try? FileManager.default.moveItem(at: url, to: saved)
                    let asset = AVURLAsset(url: saved)
                    let duration = (try? await asset.load(.duration)).map {
                        CMTimeGetSeconds($0)
                    } ?? -1
                    return (duration, saved, failure)
                }

                let phase = 1.4
                let pause = 1.5
                let plain = await record(phase: phase, pauseSeconds: 0, name: "record-plain")
                let paused = await record(phase: phase, pauseSeconds: pause, name: "record-paused")
                report.append(String(format: "  不暂停：%.2fs（期望 ~%.1fs）", plain.duration, phase))
                report.append(
                    String(
                        format: "  中间暂停 %.1fs：%.2fs（期望 ~%.1fs，不是 ~%.1fs）",
                        pause, paused.duration, phase * 2, phase * 2 + pause
                    )
                )

                if let error = plain.error ?? paused.error {
                    report.append("error: 录制失败 —— \(error.localizedDescription)")
                    report.append("RESULT: FAIL")
                    finish(report, code: 1)
                    return
                }
                guard let url = paused.url else {
                    report.append("error: 没有拿到成片")
                    report.append("RESULT: FAIL")
                    finish(report, code: 1)
                    return
                }

                // 成片规格：像素 = 区域 × 缩放；没开系统音频时只有一条视频轨。
                let asset = AVURLAsset(url: url)
                let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                let naturalSize = (try? await videoTracks.first?.load(.naturalSize)) ?? .zero
                let expectedSize = CGSize(width: region.width * scale, height: region.height * scale)
                let sizeOK = abs((naturalSize.width) - expectedSize.width) < 3
                    && abs((naturalSize.height) - expectedSize.height) < 3
                report.append(
                    "成片 -> \(url.path)；像素 \(Int(naturalSize.width))×\(Int(naturalSize.height))、"
                        + "视频轨 \(videoTracks.count) 条 / 音频轨 \(audioTracks.count) 条"
                )

                let delta = paused.duration - plain.duration
                let plainOK = plain.duration > 0.8 && plain.duration < phase + 0.9
                let deltaOK = delta > 0.6 && delta < phase + 0.8
                budgets.append(("不暂停那次的时长 ≈ 有效时长", plainOK ? 0 : nil, 0))
                budgets.append(
                    ("暂停后被继续录制、且暂停没算进成片（Δ=\(String(format: "%.2f", delta))s）",
                     deltaOK ? 0 : nil, 0)
                )
                budgets.append(("像素尺寸 = 区域 × 缩放", sizeOK ? 0 : nil, 0))
                budgets.append(("一条视频轨、没声音时没音频轨", videoTracks.count == 1 && audioTracks.isEmpty ? 0 : nil, 0))

                report.append("延迟预算：")
                var failed = 0
                for budget in budgets {
                    let ok = budget.milliseconds != nil && budget.milliseconds! <= budget.limit
                    if !ok { failed += 1 }
                    report.append("    \(ok ? "✅" : "❌") \(budget.label)")
                }
                report.append("RESULT: \(failed == 0 ? "PASS" : "FAIL（\(failed) 项未达成）")")
                finish(report, code: failed == 0 ? 0 : 1)
            } catch {
                report.append("error: \(error.localizedDescription)")
                report.append("RESULT: FAIL")
                finish(report, code: 1)
            }
        }
    }
}

#endif
