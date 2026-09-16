import CoreGraphics
import Foundation

/// 标注的默认样式：下次截图时工具、颜色、各参数沿用上一次的取值。
///
/// 存的是「用户上次用的样子」，因此每个字段都做了范围兜底（`sanitized`），
/// 避免存档损坏或旧版本遗留的异常值把滑块 / 渲染搞崩。
///
/// @author ixxxxoooo
struct AnnotationDefaults: Equatable, Codable {
    var tool: AnnotationTool
    var color: RGBAColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
    var mosaicBlock: CGFloat
    var blurRadius: CGFloat
    var magnifierZoom: CGFloat
    var eraserSize: CGFloat

    static let standard = AnnotationDefaults()

    init(
        tool: AnnotationTool = .rectangle,
        color: RGBAColor = .red,
        lineWidth: CGFloat = 7,
        fontSize: CGFloat = 22,
        mosaicBlock: CGFloat = 10,
        blurRadius: CGFloat = 12,
        magnifierZoom: CGFloat = 2,
        eraserSize: CGFloat = 28
    ) {
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.mosaicBlock = mosaicBlock
        self.blurRadius = blurRadius
        self.magnifierZoom = magnifierZoom
        self.eraserSize = eraserSize
    }

    /// 夹到与 UI 滑块一致的范围。
    var sanitized: AnnotationDefaults {
        var copy = self
        copy.lineWidth = Self.clamp(lineWidth, 1...24, fallback: 7)
        copy.fontSize = Self.clamp(fontSize, 10...100, fallback: 22)
        copy.mosaicBlock = Self.clamp(mosaicBlock, 4...40, fallback: 10)
        copy.blurRadius = Self.clamp(blurRadius, 2...60, fallback: 12)
        copy.magnifierZoom = Self.clamp(magnifierZoom, 1.5...6, fallback: 2)
        copy.eraserSize = Self.clamp(eraserSize, 8...120, fallback: 28)
        copy.color = color.sanitized
        return copy
    }

    private static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
