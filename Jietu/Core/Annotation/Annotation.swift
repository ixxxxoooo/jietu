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
        case .select: return L10n.toolSelect
        case .rectangle: return L10n.toolRectangle
        case .ellipse: return L10n.toolEllipse
        case .arrow: return L10n.toolArrow
        case .line: return L10n.toolLine
        case .pen: return L10n.toolPen
        case .highlight: return L10n.toolHighlight
        case .spotlight: return L10n.toolSpotlight
        case .pixelate: return L10n.toolPixelate
        case .blur: return L10n.toolBlur
        case .text: return L10n.toolText
        case .counter: return L10n.toolCounter
        case .eraser: return L10n.toolEraser
        case .crop: return L10n.toolCrop
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
            let language = AppLanguage(
                rawValue: UserDefaults.standard.string(forKey: "appearance.language")
                    ?? AppLanguage.system.rawValue
            ) ?? .system
            return language.resolvedCode.hasPrefix("zh")
                ? "character.cursor.ibeam.zh" : "character.cursor.ibeam"
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
        /// 直线或曲线（不带箭头）。`control` 为可选的二次贝塞尔曲率控制点。
        case line(from: CGPoint, to: CGPoint, control: CGPoint?)
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

extension Annotation.Kind {
    /// 兼容无控制点的纯直线调用。
    static func line(from: CGPoint, to: CGPoint) -> Annotation.Kind {
        .line(from: from, to: to, control: nil)
    }
}
