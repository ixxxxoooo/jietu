#if DEBUG
import QuartzCore

/// 点按响应量测（DEBUG）。
///
/// 「灵敏」这件事必须能被量出来，否则只能靠感觉吵架。这里记的是控件自己能看到的两段：
/// - `feedback`：按下事件 → 控件开始画按下反馈（AppKit 同步处理，正常应在 1ms 内）；
/// - `action`：抬起事件 → 动作闭包开始执行。
///
/// 用户真正感知的那一段（点下去 → 窗口关掉 / 弹窗出现）跨了业务层，控件量不到，
/// 由自检 `--selftest-quickaccess` 在外面用挂钟量，两边合起来才是一份完整读数。
///
/// 时间戳用 `NSEvent.timestamp`（开机秒数），与 `CACurrentMediaTime()` 同源，可直接相减。
///
/// @author ixxxxoooo
@MainActor
enum InteractionMetrics {
    enum Phase: String {
        case feedback = "按下→反馈"
        case action = "抬起→动作"
    }

    struct Sample {
        let name: String
        let phase: Phase
        let milliseconds: Double
    }

    /// 只在自检期间记录：日常使用里攒着没人看，还要占内存。
    private(set) static var isEnabled = false
    private(set) static var samples: [Sample] = []

    static func enable() { isEnabled = true }

    static func reset() { samples.removeAll() }

    /// 记一条。`eventTimestamp` 来自别的时刻（合成事件 / 时钟跳变）时丢掉——
    /// 那种样本会得出几百秒的「延迟」，除了误导没有用处。
    static func record(name: String, phase: Phase, eventTimestamp: TimeInterval) {
        guard isEnabled, eventTimestamp > 0 else { return }
        let milliseconds = (CACurrentMediaTime() - eventTimestamp) * 1000
        guard milliseconds >= 0, milliseconds < 1000 else { return }
        samples.append(Sample(name: name, phase: phase, milliseconds: milliseconds))
    }

    /// 每种「控件 · 相位」一行：次数 / 均值 / 最大。
    static func report() -> [String] {
        guard !samples.isEmpty else { return ["    （没有采样）"] }
        var grouped: [String: [Double]] = [:]
        for sample in samples {
            grouped["\(sample.name)·\(sample.phase.rawValue)", default: []].append(sample.milliseconds)
        }
        return grouped.keys.sorted().map { key in
            let values = grouped[key] ?? []
            let maximum = values.max() ?? 0
            let mean = values.reduce(0, +) / Double(values.count)
            return String(
                format: "    %@  n=%d  均值 %.2f ms  最大 %.2f ms", key, values.count, mean, maximum
            )
        }
    }

    /// 某个相位里最慢的一次，用来判 PASS / FAIL。
    static func maximum(_ phase: Phase) -> Double {
        samples.filter { $0.phase == phase }.map(\.milliseconds).max() ?? 0
    }
}
#endif
