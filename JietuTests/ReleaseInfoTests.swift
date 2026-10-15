import Testing

@testable import Jietu

struct ReleaseInfoTests {
    private let all: [UpdateError] = [
        .noInstallableAsset, .invalidResponse, .httpStatus(500), .checksumMissing, .checksumMismatch,
        .downloadFailed("x"), .unpackFailed("x"), .validationFailed("x"),
        .cannotInstallInPlace("x"), .installerLaunchFailed("x"),
    ]

    @Test func 每种错误都有可读描述且没有漏掉的占位符() {
        for error in all {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty, "\(error)")
            #expect(!text.hasPrefix("update."), "本地化键没有命中: \(text)")
            #expect(!text.contains("%@") && !text.contains("%d"), "占位符未替换: \(text)")
        }
    }

    @Test func HTTP状态码会写进描述() {
        #expect(UpdateError.httpStatus(503).errorDescription?.contains("503") == true)
    }
}
