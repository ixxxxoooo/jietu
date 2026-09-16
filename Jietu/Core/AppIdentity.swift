import Foundation

/// 当前构建的身份信息。
///
/// Debug 构建是**独立的开发渠道**（独立 bundle id `com.liwenjiao.jietu.dev` 与展示名
/// 「Jietu Dev」，对齐参考项目 `project.yml` 里 Debug 用 `PRODUCT_NAME` +
/// `PRODUCT_BUNDLE_IDENTIFIER` 分渠道的做法）：本地调试产生的 TCC 授权、偏好、
/// 登录项都不会和正式版互相污染，系统设置里也能一眼认出该给哪一条打勾。
///
/// @author ixxxxoooo
enum AppIdentity {
    /// 系统设置里显示的名字（Debug 为「Jietu Dev」）。
    static var displayName: String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            !name.isEmpty
        {
            return name
        }
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
            !name.isEmpty
        {
            return name
        }
        return "Jietu"
    }

    /// 是否 dev 渠道：bundle id 以 `.dev` 结尾。
    static var isDevChannel: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
    }

    /// bundle id，便于排查 TCC 授权对象。
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "unknown"
    }
}
