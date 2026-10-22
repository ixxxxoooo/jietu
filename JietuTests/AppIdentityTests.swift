import Foundation
import Testing
@testable import Jietu

/// 当前构建的身份（展示名 / 渠道 / bundle id）。
///
/// @author ixxxxoooo
@Suite("构建身份")
struct AppIdentityTests {
    @Test("bundle id 与渠道判定一致：以 .dev 结尾才算 dev 渠道")
    func channelMatchesBundleIdentifier() {
        #expect(AppIdentity.bundleIdentifier != "unknown", "测试宿主应当有 bundle id")
        #expect(AppIdentity.isDevChannel == AppIdentity.bundleIdentifier.hasSuffix(".dev"))
    }

    @Test("展示名非空")
    func displayNameIsNotEmpty() {
        #expect(!AppIdentity.displayName.isEmpty)
    }

    #if DEBUG
    @Test("Debug 构建是独立的 dev 渠道：Jietu Dev / com.ixxxxoooo.jietu.dev")
    func debugBuildIsDevChannel() {
        #expect(AppIdentity.isDevChannel)
        #expect(AppIdentity.bundleIdentifier == "com.ixxxxoooo.jietu.dev")
        #expect(AppIdentity.displayName == "Jietu Dev")
    }
    #endif
}
