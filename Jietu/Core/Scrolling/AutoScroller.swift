import AppKit
import ApplicationServices

/// 自动滚动：往选区里**合成滚轮事件**，让长截图不用手动滚。
///
/// 照 capcap 的做法（`Capture/AutoScroller.swift`）：
/// - 每步发一次**固定像素**的滚动，步长由调用方按选区高度算（约 15%）；
///   匀速 + 均匀间隔 → 帧间重叠稳定，拼接比手动滚靠谱得多；
/// - 同时装一个 session 级 **event tap**：用户在选区里的鼠标 / 滚轮输入被丢掉
///   （自己的合成事件带 tag，放行），**任意按键即结束**并吞掉该按键；
/// - 需要「辅助功能」权限，否则 `CGEvent.post` 会静默失效。
///
/// @author ixxxxoooo
@MainActor
final class AutoScroller {
    /// 合成事件打的标记：event tap 靠它区分「自己的滚动」和「用户的滚动」。
    private nonisolated static let syntheticTag: Int64 = 0x6A69_6574_0001  // "jiet" + marker

    /// 自动滚动的步长（点）：选区高度的 15%，夹在 60...180 之间。
    ///
    /// 步长越小重叠越多（15% 步长 ≈ 85% 重叠），拼接越稳；步长过大会漏内容。
    static func stepPoints(forHeight height: CGFloat) -> Int {
        Int(max(60, min(180, height * 0.15)))
    }

    /// 都是不可变值，`nonisolated` 是为了能在事件 tap 回调里直接读。
    private nonisolated let center: CGPoint  // 全局 cg 坐标（原点主屏左上）
    private nonisolated let blockingRect: CGRect  // 全局 cg 坐标：这块里的用户输入会被丢掉
    private nonisolated let stepPoints: Int
    private let source = CGEventSource(stateID: .hidSystemState)

    /// 用户按了任意键：由宿主收工。
    var onKeyPressed: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(center: CGPoint, blockingRect: CGRect, stepPoints: Int) {
        self.center = center
        self.blockingRect = blockingRect
        self.stepPoints = max(20, stepPoints)
    }

    /// 发一步合成滚动。`wheel1` 取负 → 页面内容往下走（长截图要的方向）。
    func postScrollStep(reversed: Bool = false) {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 1,
                wheel1: Int32(reversed ? stepPoints : -stepPoints),
                wheel2: 0,
                wheel3: 0
            )
        else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        event.location = center
        event.post(tap: .cghidEventTap)
    }

    // MARK: - 输入屏蔽

    /// 装输入屏蔽：选区内的用户鼠标 / 滚轮事件丢掉，任意键结束。
    ///
    /// 没有权限时 `tapCreate` 会失败——那只意味着**用户没被挡住**，
    /// 自动滚动本身照常（合成事件是另一回事）。
    func installInputBlocker() {
        let types: [CGEventType] = [
            .keyDown,
            .scrollWheel,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let scroller = Unmanaged<AutoScroller>
                        .fromOpaque(refcon).takeUnretainedValue()
                    return scroller.handleTappedEvent(type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            NSLog("[Jietu] auto-scroll: event tap unavailable, user input not blocked")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    func removeInputBlocker() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // 清理统一走 `removeInputBlocker()`（宿主在收工时会调）。
    // 刻意不在 deinit 里碰 `eventTap`：它是非 Sendable 的 CFMachPort，
    // 在 nonisolated 的 deinit 里访问会被拒绝。

    /// 每个被 tap 的事件在这里定去向（跑在主 run loop 上）。
    private nonisolated func handleTappedEvent(
        type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // tap 的 run loop source 就挂在主 run loop 上，这里确实在主线程。
            MainActor.assumeIsolated {
                if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return passthrough

        case .scrollWheel:
            // 自己发的合成滚动必须放行，否则页面根本不动。
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag {
                return passthrough
            }
            return blockingRect.contains(event.location) ? nil : passthrough

        case .keyDown:
            MainActor.assumeIsolated { onKeyPressed?() }
            return nil

        default:
            return blockingRect.contains(event.location) ? nil : passthrough
        }
    }
}
