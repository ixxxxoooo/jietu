import Foundation
import Testing
@testable import Jietu

/// CaptureError 枚举的消息映射测试。
///
/// @author ygw
@Suite("截图错误消息")
struct CaptureErrorTests {

    @Test("每种错误都有非空的本地化描述")
    func allCasesHaveDescriptions() {
        let cases: [CaptureError] = [
            .permissionDenied,
            .noShareableContent("test"),
            .noDisplays,
            .displayNotShareable(1),
            .emptyImage(1),
            .emptyRegion,
            .windowNotCapturable(1),
            .noWindowUnderCursor,
        ]
        for error in cases {
            #expect(error.errorDescription != nil, "\(error) 应有 errorDescription")
            #expect(!error.errorDescription!.isEmpty, "\(error) 的 errorDescription 不应为空")
        }
    }

    @Test("每种错误都有非空的恢复建议")
    func allCasesHaveRecoverySuggestions() {
        let cases: [CaptureError] = [
            .permissionDenied,
            .noShareableContent("test"),
            .noDisplays,
            .displayNotShareable(1),
            .emptyImage(1),
            .emptyRegion,
            .windowNotCapturable(1),
            .noWindowUnderCursor,
        ]
        for error in cases {
            #expect(error.recoverySuggestion != nil, "\(error) 应有 recoverySuggestion")
        }
    }

    @Test("权限相关的错误建议重启")
    func permissionErrorsSuggestRelaunch() {
        #expect(CaptureError.permissionDenied.suggestsRelaunch == true)
        #expect(CaptureError.noShareableContent("detail").suggestsRelaunch == true)
        #expect(CaptureError.displayNotShareable(1).suggestsRelaunch == true)
    }

    @Test("选区相关的错误不建议重启")
    func regionErrorsDontSuggestRelaunch() {
        #expect(CaptureError.emptyRegion.suggestsRelaunch == false)
        #expect(CaptureError.noDisplays.suggestsRelaunch == false)
        #expect(CaptureError.noWindowUnderCursor.suggestsRelaunch == false)
    }

    @Test("权限拒绝描述包含关键词")
    func permissionDeniedDescription() {
        let desc = CaptureError.permissionDenied.errorDescription!
        #expect(desc.contains("权限"), "应提到权限")
    }
}
