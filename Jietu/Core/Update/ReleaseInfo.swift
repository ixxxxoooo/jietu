import Foundation

/// 一个可安装的发布版本（来自 GitHub Release）。
///
/// @author ixxxxoooo
nonisolated struct ReleaseInfo: Equatable, Sendable, Identifiable {
    /// 语义化版本。
    let version: SemanticVersion
    /// 原始标签（如 `v0.2.0`）。
    let tag: String
    /// 发布标题。
    let name: String
    /// 更新说明（Markdown 原文）。
    let notes: String
    /// Release 网页。
    let pageURL: URL
    /// 发布时间。
    let publishedAt: Date?
    /// 安装包（zip）下载地址。
    let zipURL: URL
    /// 安装包文件名。
    let zipName: String
    /// 安装包大小（字节），未知为 0。
    let zipSize: Int64
    /// 安装包 SHA-256（小写十六进制），API 未提供时为 nil。
    let sha256: String?
    /// 校验文件（`*.sha256`）地址，没有内置摘要时用它取得校验值。
    let checksumURL: URL?

    var id: String { tag }
}

/// 更新流程里的错误。
nonisolated enum UpdateError: LocalizedError, Equatable {
    case noInstallableAsset
    case invalidResponse
    case httpStatus(Int)
    case checksumMissing
    case checksumMismatch
    case downloadFailed(String)
    case unpackFailed(String)
    case validationFailed(String)
    case cannotInstallInPlace(String)
    case installerLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInstallableAsset: return L10n.s("update.error.no_asset")
        case .invalidResponse: return L10n.s("update.error.invalid_response")
        case .httpStatus(let code): return L10n.sf("update.error.http_status", code)
        case .checksumMissing: return L10n.s("update.error.checksum_missing")
        case .checksumMismatch: return L10n.s("update.error.checksum_mismatch")
        case .downloadFailed(let message): return L10n.sf("update.error.download_failed", message)
        case .unpackFailed(let message): return L10n.sf("update.error.unpack_failed", message)
        case .validationFailed(let message): return L10n.sf("update.error.validation_failed", message)
        case .cannotInstallInPlace(let message): return message
        case .installerLaunchFailed(let message): return L10n.sf("update.error.launch_failed", message)
        }
    }
}
