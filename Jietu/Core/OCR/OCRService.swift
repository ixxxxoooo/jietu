import AppKit
import Vision

/// 文字识别（OCR）。
///
/// 基于 Vision `VNRecognizeTextRequest`，中文 + 英文，准确模式。
/// 放在后台队列执行，避免卡住 UI；`CGImage` 与请求对象都在后台闭包里创建，
/// 不跨隔离域捕获，符合 Swift 6 并发检查。
///
/// @author ixxxxoooo
enum OCRService {
    /// 识别图片中的文字。返回按行拼接的结果；失败返回空串。
    static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "en-US"]

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let lines = (request.results ?? []).compactMap {
                        $0.topCandidates(1).first?.string
                    }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    NSLog("[Jietu] OCR failed: \(error.localizedDescription)")
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
