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
    var eraserSize: CGFloat
    var arrowStyle: ArrowStyle
    var shapeFillMode: ShapeFillMode
    var textHasStroke: Bool
    var textHasCallout: Bool

    static let standard = AnnotationDefaults()

    enum CodingKeys: String, CodingKey {
        case tool, color, lineWidth, fontSize, mosaicBlock, blurRadius, eraserSize
        case arrowStyle, shapeFillMode, textHasStroke, textHasCallout
    }

    init(
        tool: AnnotationTool = .rectangle,
        color: RGBAColor = .red,
        lineWidth: CGFloat = 7,
        fontSize: CGFloat = 22,
        mosaicBlock: CGFloat = 10,
        blurRadius: CGFloat = 12,
        eraserSize: CGFloat = 28,
        arrowStyle: ArrowStyle = .tapered,
        shapeFillMode: ShapeFillMode = .none,
        textHasStroke: Bool = false,
        textHasCallout: Bool = false
    ) {
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.mosaicBlock = mosaicBlock
        self.blurRadius = blurRadius
        self.eraserSize = eraserSize
        self.arrowStyle = arrowStyle
        self.shapeFillMode = shapeFillMode
        self.textHasStroke = textHasStroke
        self.textHasCallout = textHasCallout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = try container.decodeIfPresent(AnnotationTool.self, forKey: .tool) ?? .rectangle
        color = try container.decodeIfPresent(RGBAColor.self, forKey: .color) ?? .red
        lineWidth = try container.decodeIfPresent(CGFloat.self, forKey: .lineWidth) ?? 7
        fontSize = try container.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 22
        mosaicBlock = try container.decodeIfPresent(CGFloat.self, forKey: .mosaicBlock) ?? 10
        blurRadius = try container.decodeIfPresent(CGFloat.self, forKey: .blurRadius) ?? 12
        eraserSize = try container.decodeIfPresent(CGFloat.self, forKey: .eraserSize) ?? 28
        arrowStyle = try container.decodeIfPresent(ArrowStyle.self, forKey: .arrowStyle) ?? .tapered
        shapeFillMode = try container.decodeIfPresent(ShapeFillMode.self, forKey: .shapeFillMode) ?? .none
        textHasStroke = try container.decodeIfPresent(Bool.self, forKey: .textHasStroke) ?? false
        textHasCallout = try container.decodeIfPresent(Bool.self, forKey: .textHasCallout) ?? false
    }

    /// 夹到与 UI 滑块一致的范围。
    var sanitized: AnnotationDefaults {
        var copy = self
        copy.lineWidth = Self.clamp(lineWidth, 1...24, fallback: 7)
        copy.fontSize = Self.clamp(fontSize, 10...100, fallback: 22)
        copy.mosaicBlock = Self.clamp(mosaicBlock, 4...40, fallback: 10)
        copy.blurRadius = Self.clamp(blurRadius, 2...60, fallback: 12)
        copy.eraserSize = Self.clamp(eraserSize, 8...120, fallback: 28)
        copy.color = color.sanitized
        return copy
    }

    private static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
