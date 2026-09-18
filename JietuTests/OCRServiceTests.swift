import AppKit
import Testing
@testable import Jietu

@Suite("文字识别服务")
struct OCRServiceTests {
    private func createTextImage(text: String, size: CGSize = CGSize(width: 400, height: 200)) -> CGImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20),
            .foregroundColor: NSColor.black,
        ]
        (text as NSString).draw(at: NSPoint(x: 20, y: 80), withAttributes: attrs)
        image.unlockFocus()
        var rect = CGRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
    }

    @Test("识别简体与繁体中文及英文混合")
    func recognizeMixedText() async {
        let text = "你好世界 繁體中文 Hello 123"
        let cg = createTextImage(text: text)
        let result = await OCRService.recognizeText(in: cg)
        #expect(result.contains("你好世界") || result.contains("繁體中文") || result.contains("Hello"))
    }

    @Test("纯黑空白无文字图片返回空字符串")
    func emptyImageReturnsEmpty() async {
        let base = TestImage.solidBlack(side: 64)
        let result = await OCRService.recognizeText(in: base)
        #expect(result.isEmpty)
    }
}
