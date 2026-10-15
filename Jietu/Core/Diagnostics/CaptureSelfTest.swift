import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG

/// 命令行自检入口，只在 Debug 构建里编译。
///
/// 存在的原因：屏幕捕获的失败模式大多发生在「UI 之前」（权限、坐标、缩放），
/// 靠肉眼点界面很难定位。这两个开关让捕获链路可以无人值守地跑通并留下证据。
///
///   Jietu --selftest-capture <输出目录>     冻结全部屏幕 → 落 PNG → 打印报告 → 退出
///   Jietu --selftest-overlay <持续秒数>     冻结全部屏幕 → 弹出遮罩 → 保持 N 秒 → 退出
///   Jietu --selftest-region x,y,w,h         核对 SCK sourceRect 坐标系（直接抓 vs 整屏裁）
///   Jietu --selftest-chrome x,y,w,h         取景框态下「含 / 不含本 App」各抓一张，辨黑屏
///   Jietu --selftest-session x,y,w,h        不弹遮罩，直接跑真实采样会话（自动滚动）
///   Jietu --selftest-frames x,y,w,h [--with-blocker]
///                                           逐拍 dump 帧 + 平均差 / Vision 位移 / 拼接判定
///   Jietu --selftest-scrollprobe x,y,w,h    几种合成滚轮写法哪个能真的推动目标窗口
///   Jietu --selftest-quickaccess <输出目录> 浮窗图标：逐个注入点击，量响应速度（含截图）
///   Jietu --selftest-scroll-cost            滚动长图每帧成本：拼接 / 预览（含老做法对比）
///   Jietu --selftest-record <输出目录>       录屏：真录一段（含暂停），读回成片验时长/尺寸
///   Jietu --selftest-video-tools <输出目录>   成片再加工：GIF 导出 + 裁剪导出，读回产物校验
///   Jietu --selftest-inline-draw <输出目录>   就地标注：验证「框里还能再画框」
///   Jietu --selftest-inline-scroll <输出目录>
///                                           就地工具栏的「滚动截图」：点开手动 / 自动并截图
///   Jietu --selftest-overlay-press <输出目录>
///                                           吸附预览：量「按下 → 窗口描边消失」，拖动中不许回来
enum CaptureSelfTest {
    /// 需要**完整 App 接线**的自检开关。
    ///
    /// 它不归 `handleCommandLineIfNeeded` 管（那个只看 `--selftest` 前缀，认不出的开关一律放行，
    /// 于是启动流程会继续把菜单栏 / 各种 controller 接好），由 `AppDelegate` 接完线之后执行。
    /// 单例守卫也要为它放行：它经常与正式实例同时在场。
    static let appLevelInlineScrollFlag = "--selftest-app-inline-scroll"

    /// 需要完整接线的录屏自检：菜单/遮罩/红框/控制条/落盘，一条链走完。
    static let appLevelRecordingFlag = "--selftest-app-record"

    /// 成片再加工自检（GIF / 裁剪）：只造合成视频 + 转码，不建窗口、不抢屏幕，
    /// 所以它**允许**与正式实例同时在场（单例守卫为它放行）。
    static let videoToolsFlag = "--selftest-video-tools"

    /// 真接线打开裁剪窗口：复现「点裁剪就退出应用」这类只在完整接线里出现的问题。
    static let appLevelTrimFlag = "--selftest-app-trim"

    /// 麦克风采集：真开一次输入设备，验「硬件格式 → 写入格式」的转换链路。
    /// 只读设备、不建窗口，可以和正式实例同时在跑。
    static let microphoneFlag = "--selftest-microphone"

    /// 「最近截图」子菜单长什么样：空历史 / 有截图各弹一次拍一张。
    static let appLevelRecentMenuFlag = "--selftest-app-recent-menu"

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

        case "--selftest-region":
            // 核对 SCK 的 sourceRect 坐标系：同一块区域「直接抓」与「整屏抓再裁」应当一致。
            runRegionTest(
                spec: value ?? "0,0,400,300",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-chrome":
            // 滚动长图取景框态：遮罩留着 + 本 App 被排除时，区域抓取到底拍到了什么。
            runChromeTest(
                spec: value ?? "400,400,700,500",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-scrollprobe":
            // 合成滚动到底能不能推动目标窗口：把几种事件写法逐个试一遍。
            runScrollProbe(
                spec: value ?? "400,400,700,500",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-frames":
            // 逐步滚动 + 逐帧 dump：看清「滚动到底有没有推动画面 / 拼接为什么拒绝这帧」。
            runFramesTest(
                spec: value ?? "400,400,700,500",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-session":
            // 不弹遮罩，直接跑一遍真实采样会话（自动滚动），复现「没有捕获到滚动内容」。
            runSessionTest(
                spec: value ?? "400,400,700,500",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-scroll-cost":
            // 滚动长图的每帧成本：拼接（Vision / 已知步长）、右侧预览、老做法对比。
            runScrollCostTest()
            return true

        case "--selftest-record":
            // 录屏：真录一段（中间暂停一次），再用 AVFoundation 读回成片验时长 / 尺寸 / 音视频轨。
            runRecordTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case videoToolsFlag:
            // 成片再加工：造一段合成视频，跑真实的 GIF 导出与裁剪导出，读回产物校验。
            VideoToolsSelfTest.run(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case microphoneFlag:
            // 麦克风采集：硬件格式（可能是 48kHz 单声道）→ 写入格式（44.1kHz 双声道）。
            MicrophoneSelfTest.run()
            return true

        case "--selftest-inline-draw":
            // 就地标注：框里还能再画框（矩形/椭圆只认边框，中间是留白）。
            runInlineDrawTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case "--selftest-inline-scroll":
            // 就地编辑工具栏的「滚动截图」：点开手动 / 自动，选完把选区交出去。
            runInlineScrollTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case "--selftest-overlay-press":
            // 吸附预览「按下即收」：鼠标所在窗口的描边，在按下的那一刻就该消失。
            runOverlayPressTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case "--selftest-loupe":
            // 选区放大镜：合成一次「按下 → 拖动 → 停住」，截图看网格 / 读数面板。
            runLoupeTest(
                spec: value ?? "700,600,600,300",
                outputDirectory: outputDirectory(arguments, after: flagIndex)
            )
            return true

        case "--selftest-pin":
            // 钉图：把一张**纯白**图钉在屏幕正中，看两个浮动按钮在白底上还认不认得出来。
            runPinTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case "--selftest-quickaccess":
            // 浮窗图标：真弹一张浮窗、真点每个图标，量「按下 → 反馈 / 动作 / 可见效果」。
            runQuickAccessTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                )
            )
            return true

        case "--selftest-editor":
            // 标注编辑器：拿一张很小的图开窗，截图检查工具栏有没有被窗口裁掉。
            runEditorTest(
                outputDirectory: URL(
                    fileURLWithPath: value ?? NSTemporaryDirectory(),
                    isDirectory: true
                ),
                inline: !arguments.contains("--window")
            )
            return true

        default:
            return false
        }
    }

    /// `--selftest-xxx <参数> [输出目录]` 里的输出目录（缺省落临时目录）。
    static func outputDirectory(_ arguments: [String], after flagIndex: Int) -> URL {
        arguments.count > flagIndex + 2
            ? URL(fileURLWithPath: arguments[flagIndex + 2], isDirectory: true)
            : URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// 自检报告里的毫秒格式（两批自检共用；nil = 没等到）。
    static func describe(milliseconds: Double?) -> String {
        guard let milliseconds else { return "**超时**" }
        return String(format: "%.0f ms", milliseconds)
    }

    static func describe(_ values: [CGFloat]) -> String {
        values.map { String(format: "%.2f", $0) }.joined(separator: " / ")
    }

    static func postMouse(_ type: CGEventType, at point: CGPoint) {
        CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    /// 自检用的小图：彩色块 + 斜线，够看出缩放 / 裁切（app 级自检也要用）。
    static func makeTestImage(width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw CaptureError.emptyImage(0) }
        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let colors: [CGColor] = [
            CGColor(red: 0.95, green: 0.4, blue: 0.4, alpha: 1),
            CGColor(red: 0.4, green: 0.7, blue: 0.95, alpha: 1),
            CGColor(red: 0.5, green: 0.85, blue: 0.5, alpha: 1),
        ]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color)
            let size = CGFloat(min(width, height) / 4)
            context.fill(
                CGRect(
                    x: 8 + CGFloat(index) * (size + 8), y: CGFloat(height) - size - 8,
                    width: size, height: size
                )
            )
        }
        guard let image = context.makeImage() else { throw CaptureError.emptyImage(0) }
        return image
    }

    /// 把 `x,y,w,h` 解析成矩形（显示器内点坐标、原点左上——与滚动长图的 sourceRect 约定一致）。
    static func parseRect(_ spec: String) -> CGRect? {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// 写 PNG（app 级自检也要用）。
    static func writePNG(_ image: CGImage, to url: URL) throws {
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

    /// 自检报告里的矩形格式（两批自检共用）。
    static func describe(_ rect: CGRect) -> String {
        String(
            format: "(%.0f,%.0f %.0fx%.0f)",
            rect.origin.x, rect.origin.y, rect.width, rect.height
        )
    }

    /// 自检报告输出（`--selftest-` 与 `--selftest-app-` 两批共用）。
    static func finish(_ lines: [String], code: Int32) {
        // `exit()` **不会**执行 defer，所以自检里「改过的设置一律还回去」那类 defer 全是摆设
        // （实测：跑完 `--selftest-app-record` 后用户的保存目录一直留在临时目录里）。
        // 要还原的动作注册到 `cleanupBeforeExit`，这里统一跑一遍再退。
        for action in cleanupBeforeExit { action() }
        cleanupBeforeExit.removeAll()
        print("=== Jietu selftest ===")
        for line in lines { print(line) }
        print("======================")
        fflush(stdout)
        // 再落一份文件：有些场景必须走 LaunchServices 启动（TCC 才认权限，见麦克风自检），
        // 那种情况下看不到 stdout，报告只能从文件读。
        let report = (["=== Jietu selftest ==="] + lines + ["======================"])
            .joined(separator: "\n")
        try? report.write(
            to: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("jietu-selftest-report.txt"),
            atomically: true, encoding: .utf8
        )
        exit(code)
    }

    /// 自检退出前要做的清理（还原改过的设置、删临时文件）。
    ///
    /// 跨 Actor 访问：`exit()` 前同步执行，与自检的 MainActor 上下文无关。
    nonisolated(unsafe) static var cleanupBeforeExit: [() -> Void] = []

    /// 报告里用的矩形文本（几何类断言读起来省事）。
    static func rectText(_ rect: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0f×%.0f)", rect.minX, rect.minY, rect.width, rect.height)
    }
}

#endif
