import AppKit
import Vision

/// 文字识别（OCR）。
///
/// 深度利用 macOS 原生 Vision 框架（`VNRecognizeTextRequest`）：
/// 1. 启用 macOS 自带的自动语言检测（`automaticallyDetectsLanguage`），全面支持简体中文、繁体中文、英文、数字与代码；
/// 2. 支持静默预热（`warmUp`），消除冷启动 10~15 秒模型加载耗时，使实际识别达到 0.1~0.3 秒毫秒级响应；
/// 3. 原生 Vision 框架避免了高层级 VisionKit 在非标准环境下的 XPC 卡顿与长达数十秒的空扫描重试。
///
/// @author ixxxxoooo
enum OCRService {
    /// 预热 Vision 识别模型，消除首次调用时 10~15 秒的模型冷启动加载耗时。
    static func warmUp() {
        Task.detached(priority: .background) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let dummy = ctx.makeImage() else { return }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = true
            }
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            let handler = VNImageRequestHandler(cgImage: dummy, options: [:])
            try? handler.perform([request])
        }
    }

    /// 识别图片中的文字。返回按行拼接的结果；失败返回空串。
    static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                if #available(macOS 13.0, *) {
                    request.automaticallyDetectsLanguage = true
                }
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let lines = (request.results ?? []).compactMap {
                        $0.topCandidates(1).first?.string
                    }
                    if !lines.isEmpty {
                        continuation.resume(returning: lines.joined(separator: "\n"))
                        return
                    }
                } catch {
                    NSLog("[Jietu] Accurate OCR failed: \(error.localizedDescription), falling back to fast mode")
                }

                // 兜底：当 accurate 模式因 ANE / 模型临时加载失败时，退回 fast 模式重试
                let fallbackRequest = VNRecognizeTextRequest()
                fallbackRequest.recognitionLevel = .fast
                fallbackRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                do {
                    try handler.perform([fallbackRequest])
                    let lines = (fallbackRequest.results ?? []).compactMap {
                        $0.topCandidates(1).first?.string
                    }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    NSLog("[Jietu] Fallback OCR failed: \(error.localizedDescription)")
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
