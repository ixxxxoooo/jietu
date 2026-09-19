import Foundation

/// 测试用的独立 UserDefaults 工厂：每次生成唯一 suite，测试之间互不影响。
///
/// @author ygw
enum TestUserDefaults {
    /// 创建一对 (UserDefaults, suiteName)，用完后可用 suiteName 清理。
    static func make() -> (UserDefaults, String) {
        let suite = "jietu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
