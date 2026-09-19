import AppKit

struct RGBAColor: Equatable, Hashable, Codable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// 夹到 0...1；用于读取可能损坏的存档值。
    var sanitized: RGBAColor {
        func clamp(_ value: CGFloat) -> CGFloat {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), 1)
        }
        return RGBAColor(red: clamp(red), green: clamp(green), blue: clamp(blue), alpha: clamp(alpha))
    }

    static let red = RGBAColor(red: 1.0, green: 0.231, blue: 0.188, alpha: 1)       // #FF3B30
    static let blue = RGBAColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1)        // #007AFF
    static let green = RGBAColor(red: 0.0, green: 0.831, blue: 0.420, alpha: 1)     // #00D46B
    static let yellow = RGBAColor(red: 1.0, green: 0.800, blue: 0.0, alpha: 1)      // #FFCC00
    static let orange = RGBAColor(red: 0.843, green: 0.467, blue: 0.341, alpha: 1)  // #D77757
    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)               // #FFFFFF
    static let gray = RGBAColor(red: 0.502, green: 0.502, blue: 0.502, alpha: 1)    // #808080
    static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)               // #000000

    static let palette: [RGBAColor] = [.red, .blue, .green, .yellow, .orange, .white, .gray, .black]
}

/// 箭头端点样式。
///
/// @author ixxxxoooo
enum ArrowStyle: String, CaseIterable, Identifiable, Codable {
    case tapered
    case doubleEnded
    case line
    case dotTail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tapered: return L10n.arrowTapered
        case .doubleEnded: return L10n.arrowDoubleEnded
        case .line: return L10n.arrowLine
        case .dotTail: return L10n.arrowDotTail
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "tapered": self = .tapered
        case "doubleEnded": self = .doubleEnded
        case "line", "standard": self = .line
        case "dotTail": self = .dotTail
        default: self = .tapered
        }
    }
}

/// 矩形的角样式（方角 / 圆角）。
///
/// @author ixxxxoooo
enum RectCornerStyle: String, CaseIterable, Identifiable, Codable {
    case square
    case rounded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square: return L10n.cornerSquare
        case .rounded: return L10n.cornerRounded
        }
    }

    /// 圆角半径按短边的比例算：矩形拖大拖小，观感一致（小矩形也不会倒成胶囊）。
    /// 取一个不大的比例——圆角只是让方框显得柔和些，别一眼看上去像胶囊。
    static let roundedRadiusRatio: CGFloat = 0.08

    /// 给定矩形实际用的圆角半径（方角为 0）。
    static func radius(for rect: CGRect, style: RectCornerStyle) -> CGFloat {
        guard style == .rounded else { return 0 }
        let side = min(rect.width, rect.height)
        guard side.isFinite, side > 0 else { return 0 }
        return max(1, side * roundedRadiusRatio)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "square", "sharp": self = .square
        case "rounded": self = .rounded
        default: self = .square
        }
    }
}

/// 形状填充模式（线框、填充、半透明）。
///
/// @author ixxxxoooo
enum ShapeFillMode: String, CaseIterable, Identifiable, Codable {
    case none
    case opaque
    case translucent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return L10n.fillNone
        case .opaque: return L10n.fillOpaque
        case .translucent: return L10n.fillTranslucent
        }
    }
}

/// 可复制的标注样式：颜色 / 线宽 / 字号 / 马赛克块大小。
///
/// 「复制样式 → 粘贴样式」用它在不同标注之间搬运外观，几何量不动。
///
/// @author ixxxxoooo
struct AnnotationStyle: Equatable {
    var color: RGBAColor
    var lineWidth: CGFloat
    /// 仅当被复制的对象是文字 / 气泡时才有值。
    var fontSize: CGFloat?
    /// 仅当被复制的对象是马赛克时才有值。
    var mosaicBlock: CGFloat?
    /// 仅当被复制的对象是模糊时才有值。
    var blurRadius: CGFloat?
    var arrowStyle: ArrowStyle?
    var shapeFillMode: ShapeFillMode?
    var rectCornerStyle: RectCornerStyle?
    var textHasStroke: Bool?
    var textHasCallout: Bool?

    init(
        color: RGBAColor,
        lineWidth: CGFloat,
        fontSize: CGFloat? = nil,
        mosaicBlock: CGFloat? = nil,
        blurRadius: CGFloat? = nil,
        arrowStyle: ArrowStyle? = nil,
        shapeFillMode: ShapeFillMode? = nil,
        rectCornerStyle: RectCornerStyle? = nil,
        textHasStroke: Bool? = nil,
        textHasCallout: Bool? = nil
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.mosaicBlock = mosaicBlock
        self.blurRadius = blurRadius
        self.arrowStyle = arrowStyle
        self.shapeFillMode = shapeFillMode
        self.rectCornerStyle = rectCornerStyle
        self.textHasStroke = textHasStroke
        self.textHasCallout = textHasCallout
    }

    /// 从一条已有标注里提取样式：只带上与该类型相关的字段，
    /// 这样「马赛克 → 文字」不会把文字字号改掉。
    init(from annotation: Annotation) {
        var fontSize: CGFloat?
        switch annotation.kind {
        case .text(_, _, let size), .callout(_, _, _, _, let size):
            fontSize = size
        default:
            break
        }
        var mosaicBlock: CGFloat?
        if case .pixelate(_, let block) = annotation.kind { mosaicBlock = block }
        var blurRadius: CGFloat?
        if case .blur(_, let radius) = annotation.kind { blurRadius = radius }

        self.init(
            color: annotation.color,
            lineWidth: annotation.lineWidth,
            fontSize: fontSize,
            mosaicBlock: mosaicBlock,
            blurRadius: blurRadius,
            arrowStyle: annotation.arrowStyle,
            shapeFillMode: annotation.shapeFillMode,
            rectCornerStyle: annotation.rectCornerStyle,
            textHasStroke: annotation.textHasStroke,
            textHasCallout: annotation.textHasCallout
        )
    }

    /// 把样式套到标注上。目标类型缺什么就不改什么：字号只作用于文字 / 气泡，
    /// 块大小只作用于马赛克，模糊半径只作用于模糊，倍率只作用于放大镜。
    func applied(to annotation: Annotation) -> Annotation {
        var copy = annotation.withColor(color).withLineWidth(lineWidth)
        switch annotation.kind {
        case .text, .callout:
            if let fontSize { copy = copy.withFontSize(fontSize) }
            if let textHasStroke { copy = copy.withTextStroke(textHasStroke) }
            if let textHasCallout { copy = copy.withTextCallout(textHasCallout) }
        case .pixelate:
            if let mosaicBlock { copy = copy.withPixelateBlock(mosaicBlock) }
        case .blur:
            if let blurRadius { copy = copy.withBlurRadius(blurRadius) }
        case .arrow:
            if let arrowStyle { copy = copy.withArrowStyle(arrowStyle) }
        case .rectangle, .ellipse:
            if let shapeFillMode { copy = copy.withShapeFillMode(shapeFillMode) }
            if let rectCornerStyle, case .rectangle = annotation.kind {
                copy = copy.withRectCornerStyle(rectCornerStyle)
            }
        default:
            break
        }
        return copy
    }
}

/// 一次橡皮擦除笔迹（图像像素坐标，原点左上）。
///
/// @author ixxxxoooo
struct EraserStroke: Equatable {
    var points: [CGPoint]
    var radius: CGFloat
}

/// 一条标注对象。几何量全部为图像像素坐标（原点左上）。
///
