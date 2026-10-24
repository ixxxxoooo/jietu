import AppKit
import SwiftUI

/// Liquid Glass 的透明度偏好：跟随系统，或自定义一档「不透明度」。
///
/// 系统玻璃本身没有透明度参数，这里用**色调的浓度**来调：0 = 最通透（接近系统原样），
/// 1 = 几乎不透。读写都走 `UserDefaults.standard`，SwiftUI 侧用 `@AppStorage` 即时刷新，
/// AppKit 侧由 `FloatingGlassView` 监听变更。
///
/// @author ixxxxoooo
enum GlassOpacity {
    static let followSystemKey = "appearance.glassFollowSystem"
    static let levelKey = "appearance.glassOpacity"
    static let defaultLevel = 0.4

    /// 玻璃上叠的底色：浅色用白、深色用近黑，明暗下都读得出「变实」。
    private static func base(isDark: Bool) -> NSColor {
        isDark ? NSColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1) : .white
    }

    /// 当前该叠的色调；跟随系统时为 nil。
    ///
    /// - Parameters:
    ///   - followSystem: 是否跟随系统。
    ///   - level: 不透明度档位 0...1（越界会被夹住）。
    ///   - isDark: 当前是否深色外观。
    /// - Returns: 色调（含 alpha）或 nil。
    static func tint(followSystem: Bool, level: Double, isDark: Bool) -> NSColor? {
        guard !followSystem else { return nil }
        let clamped = min(max(level, 0), 1)
        return base(isDark: isDark).withAlphaComponent(clamped * 0.85)
    }

    /// 从 UserDefaults 读当前偏好。
    static func currentTint(isDark: Bool) -> NSColor? {
        let defaults = UserDefaults.standard
        let follow = defaults.object(forKey: followSystemKey) as? Bool ?? true
        let level = defaults.object(forKey: levelKey) as? Double ?? defaultLevel
        return tint(followSystem: follow, level: level, isDark: isDark)
    }
}

/// 持有通知观察者，供回调里自我移除。
private final class ObserverToken: @unchecked Sendable {
    var value: NSObjectProtocol?
}

/// 会随「玻璃透明度」设置即时刷新色调的 `NSGlassEffectView`。
final class FloatingGlassView: NSGlassEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        refreshTint()
        // 视图释放后 weak self 为 nil，回调里顺手把自己摘掉，避免观察者越积越多。
        let token = ObserverToken()
        token.value = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self, token] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    token.value.map(NotificationCenter.default.removeObserver)
                    return
                }
                self.refreshTint()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTint()
    }

    /// 按当前偏好和外观重设色调。
    private func refreshTint() {
        tintColor = GlassOpacity.currentTint(isDark: effectiveAppearance.isDark)
    }
}

extension View {
    /// 按「玻璃透明度」偏好渲染 SwiftUI 玻璃表面；跟随系统时与 `.glassEffect(.regular)` 完全一致。
    func floatingGlass(in shape: some Shape) -> some View {
        modifier(FloatingGlassModifier(shape: AnyShape(shape)))
    }
}

private struct FloatingGlassModifier: ViewModifier {
    let shape: AnyShape
    @AppStorage(GlassOpacity.followSystemKey) private var follow = true
    @AppStorage(GlassOpacity.levelKey) private var level = GlassOpacity.defaultLevel
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let tint = GlassOpacity.tint(followSystem: follow, level: level, isDark: scheme == .dark)
        content.glassEffect(.regular.tint(tint.map(Color.init(nsColor:))), in: shape)
    }
}
