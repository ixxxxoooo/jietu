import CoreGraphics
import CoreText
import Foundation

/// 标注工具。
///
/// @author ixxxxoooo
enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case select
    case rectangle
    case ellipse
    case arrow
    case line
    case pen
    /// 荧光笔 / 高亮笔：像真马克笔一样涂一条半透明粗笔迹。
    case highlight
    /// 聚光灯：压暗框外，只留框内清晰。
    case spotlight
    case pixelate
    case blur
    case text
    case counter
    case eraser
    /// 截后再裁剪：拖一个框，确认后把底图裁掉。
    case crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "选择"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .pen: return "画笔"
        case .highlight: return "高亮笔"
        case .spotlight: return "聚光灯"
        case .pixelate: return "马赛克"
        case .blur: return "模糊"
        case .text: return "文字"
        case .counter: return "序号"
        case .eraser: return "橡皮"
        case .crop: return "裁剪"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .pen: return "pencil"
        case .highlight: return "highlighter"
        case .spotlight: return "rectangle.inset.filled"
        case .pixelate: return "squareshape.split.3x3"
        case .blur: return "drop.halffull"
        case .text:
            let isChinese = (Locale.preferredLanguages.first?.hasPrefix("zh") ?? false)
                || (Locale.current.language.languageCode?.identifier == "zh")
            return isChinese ? "character.cursor.ibeam.zh" : "character.cursor.ibeam"
        case .counter: return "1.circle"
        case .eraser: return "eraser"
        case .crop: return "crop"
        }
    }

    /// 是否为「绘制/动作类」工具（选择工具不是）。
    var isDrawing: Bool { self != .select }
}

/// 与外观无关的 RGBA 颜色。
///
/// @author ixxxxoooo
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case rectangle(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint, control: CGPoint?)
        /// 直线（不带箭头）。
        case line(from: CGPoint, to: CGPoint)
        case pen(points: [CGPoint])
        /// 荧光笔笔迹：沿 `points` 涂一条半透明粗笔迹（笔宽见 `highlightBrushWidth`）。
        case highlight(points: [CGPoint])
        /// 聚光灯：整个画面压暗，只留 `rect` 内清晰。
        case spotlight(CGRect)
        case text(origin: CGPoint, string: String, fontSize: CGFloat)
        case pixelate(CGRect, block: CGFloat)
        /// 高斯模糊区域。
        case blur(CGRect, radius: CGFloat)
        /// 放大镜：把框内的画面按 `zoom` 放大后画在框里。
        case counter(center: CGPoint, value: Int, leader: CGPoint?)
        /// 标注气泡：序号圆点 + 箭头 + 可输入说明的文字框。
        case callout(center: CGPoint, value: Int, labelOrigin: CGPoint, string: String, fontSize: CGFloat)
        /// 橡皮擦除笔迹（恢复底图背景）。
        case eraser(points: [CGPoint], radius: CGFloat)
    }

    let id: UUID
    var kind: Kind
    var color: RGBAColor
    var lineWidth: CGFloat
    /// 绕自身中心的旋转角（弧度）。
    var rotation: CGFloat
    var arrowStyle: ArrowStyle
    var shapeFillMode: ShapeFillMode
    /// 矩形的角样式（只对 `.rectangle` 有意义）。
    var rectCornerStyle: RectCornerStyle
    var textHasStroke: Bool
    var textHasCallout: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        color: RGBAColor,
        lineWidth: CGFloat = 3,
        rotation: CGFloat = 0,
        arrowStyle: ArrowStyle = .tapered,
        shapeFillMode: ShapeFillMode = .none,
        rectCornerStyle: RectCornerStyle = .square,
        textHasStroke: Bool = false,
        textHasCallout: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
        self.rotation = rotation
        self.arrowStyle = arrowStyle
        self.shapeFillMode = shapeFillMode
        self.rectCornerStyle = rectCornerStyle
        self.textHasStroke = textHasStroke
        self.textHasCallout = textHasCallout
    }
}

