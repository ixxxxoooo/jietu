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
    case highlight
    case text
    case pixelate
    case blur
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
        case .highlight: return "高亮"
        case .text: return "文字"
        case .pixelate: return "马赛克"
        case .blur: return "模糊"
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
        case .text:
            let isChinese = (Locale.preferredLanguages.first?.hasPrefix("zh") ?? false)
                || (Locale.current.language.languageCode?.identifier == "zh")
            return isChinese ? "character.cursor.ibeam.zh" : "character.cursor.ibeam"
        case .pixelate: return "squareshape.split.3x3"
        case .blur: return "drop.halffull"
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

    static let red = RGBAColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    static let orange = RGBAColor(red: 1, green: 0.58, blue: 0, alpha: 1)
    static let yellow = RGBAColor(red: 1, green: 0.8, blue: 0, alpha: 1)
    static let green = RGBAColor(red: 0.19, green: 0.78, blue: 0.35, alpha: 1)
    static let blue = RGBAColor(red: 0.11, green: 0.55, blue: 1, alpha: 1)
    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)

    static let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .white, .black]
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

    init(
        color: RGBAColor,
        lineWidth: CGFloat,
        fontSize: CGFloat? = nil,
        mosaicBlock: CGFloat? = nil,
        blurRadius: CGFloat? = nil,
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.mosaicBlock = mosaicBlock
        self.blurRadius = blurRadius
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
        )
    }

    /// 把样式套到标注上。目标类型缺什么就不改什么：字号只作用于文字 / 气泡，
    /// 块大小只作用于马赛克，模糊半径只作用于模糊，倍率只作用于放大镜。
    func applied(to annotation: Annotation) -> Annotation {
        var copy = annotation.withColor(color).withLineWidth(lineWidth)
        switch annotation.kind {
        case .text, .callout:
            if let fontSize { copy = copy.withFontSize(fontSize) }
        case .pixelate:
            if let mosaicBlock { copy = copy.withPixelateBlock(mosaicBlock) }
        case .blur:
            if let blurRadius { copy = copy.withBlurRadius(blurRadius) }
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
/// @author ixxxxoooo
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case rectangle(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint, control: CGPoint?)
        /// 直线（不带箭头）。
        case line(from: CGPoint, to: CGPoint)
        case pen(points: [CGPoint])
        case highlight(CGRect)
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

    init(
        id: UUID = UUID(),
        kind: Kind,
        color: RGBAColor,
        lineWidth: CGFloat = 3,
        rotation: CGFloat = 0
    ) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
        self.rotation = rotation
    }
}

// MARK: - 几何

extension Annotation {
    /// 旋转中心。
    var center: CGPoint {
        switch kind {
        case .counter(let center, _, _):
            return center
        case .callout(let center, _, _, _, _):
            return center
        default:
            let box = localBounds
            return CGPoint(x: box.midX, y: box.midY)
        }
    }

    /// 未旋转的包围盒。
    var localBounds: CGRect {
        switch kind {
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .pixelate(let rect, _),
            .blur(let rect, _):
            return rect
        case .arrow(let from, let to, let control):
            var minX = min(from.x, to.x)
            var minY = min(from.y, to.y)
            var maxX = max(from.x, to.x)
            var maxY = max(from.y, to.y)
            if let control {
                minX = min(minX, control.x)
                minY = min(minY, control.y)
                maxX = max(maxX, control.x)
                maxY = max(maxY, control.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .line(let from, let to):
            return CGRect(
                x: min(from.x, to.x),
                y: min(from.y, to.y),
                width: abs(to.x - from.x),
                height: abs(to.y - from.y)
            )
        case .pen(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x
            var minY = first.y
            var maxX = first.x
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text(let origin, let string, let fontSize):
            let size = Annotation.textSize(string: string, fontSize: fontSize)
            let pad = Annotation.textPadding(fontSize: fontSize)
            return CGRect(
                x: origin.x - pad.x,
                y: origin.y - pad.y,
                width: size.width + pad.x * 2,
                height: size.height + pad.y * 2
            )
        case .counter(let center, _, let leader):
            let radius: CGFloat = 12
            var rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            if let leader { rect = rect.union(CGRect(origin: leader, size: .zero)) }
            return rect
        case .callout(let center, _, let labelOrigin, let string, let fontSize):
            let radius: CGFloat = 12
            let dot = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            return dot.union(Annotation.calloutLabelRect(origin: labelOrigin, string: string, fontSize: fontSize))
        case .eraser(let points, let radius):
            guard let first = points.first else { return .zero }
            var minX = first.x
            var minY = first.y
            var maxX = first.x
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
            return CGRect(
                x: minX - radius,
                y: minY - radius,
                width: (maxX - minX) + radius * 2,
                height: (maxY - minY) + radius * 2
            )
        }
    }

    /// 旋转到本地坐标：把点绕中心反向旋转。
    func toLocal(_ point: CGPoint) -> CGPoint {
        Annotation.rotate(point, around: center, by: -rotation)
    }

    /// 本地坐标旋转到世界坐标。
    func toWorld(_ point: CGPoint) -> CGPoint {
        Annotation.rotate(point, around: center, by: rotation)
    }

    func rotatedCorners() -> [CGPoint] {
        let box = localBounds
        return [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
        ].map(toWorld)
    }

    /// 命中测试。`tolerance` 为点选容差（像素）。
    func contains(_ point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        let local = toLocal(point)
        switch kind {
        case .rectangle(let rect):
            // 矩形**只画了边框**（渲染器走 `stroke`，中间是透明的），命中判定也只能认边框：
            // 之前按整块矩形判，于是框中间一按就变成「选中并移动这个框」，
            // 想在里面再画一个框根本画不上（用户报的就是这个）。
            return Annotation.distanceToRectBorder(local, rect: rect) <= max(tolerance, lineWidth / 2)
        case .ellipse(let rect):
            // 椭圆同理：只认那一圈线。
            return Annotation.distanceToEllipseBorder(local, rect: rect)
                <= max(tolerance, lineWidth / 2)
        case .highlight(let rect), .blur(let rect, _):
            // 这两个是**实心**的（高亮铺一层半透明色、模糊作用于整块），整块都算命中。
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(local)
        case .pixelate(let rect, _):
            return rect.contains(local)
        case .arrow(let from, let to, let control):
            return Annotation.distanceToCurve(local, from: from, to: to, control: control)
                <= max(tolerance, lineWidth)
        case .line(let from, let to):
            return Annotation.distanceToSegment(local, from, to) <= max(tolerance, lineWidth)
        case .pen(let points):
            return Annotation.distanceToPolyline(local, points: points) <= max(tolerance, lineWidth)
        case .text:
            return localBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(local)
        case .counter(let center, _, let leader):
            if Annotation.distance(local, center) <= 14 { return true }
            if let leader {
                return Annotation.distanceToSegment(local, leader, center) <= max(tolerance, lineWidth)
            }
            return false
        case .callout(let center, _, let labelOrigin, let string, let fontSize):
            if Annotation.distance(local, center) <= 14 { return true }
            return Annotation.calloutLabelRect(origin: labelOrigin, string: string, fontSize: fontSize)
                .insetBy(dx: -tolerance, dy: -tolerance)
                .contains(local)
        case .eraser:
            return false
        }
    }
}

// MARK: - 变换

extension Annotation {
    func translated(by delta: CGSize) -> Annotation {
        var copy = self
        copy.kind = Self.translateKind(kind, by: delta)
        return copy
    }

    func rotated(by delta: CGFloat) -> Annotation {
        var copy = self
        copy.rotation += delta
        return copy
    }

    /// 按矩形控制点缩放（仅对矩形类 / 画笔 / 文字字号有意义）。
    func resized(handle: ShapeHandle, to point: CGPoint, lockAspect: Bool) -> Annotation {
        let local = toLocal(point)
        var copy = self

        switch kind {
        case .rectangle, .ellipse, .highlight, .pixelate, .blur:
            let box = localBounds
            let newBox = ShapeGeometry.resizedRect(box, handle: handle, to: local, lockAspect: lockAspect)
            copy.replaceRect(newBox)
        case .pen(let points):
            guard !points.isEmpty else { break }
            let box = localBounds
            let newBox = ShapeGeometry.resizedRect(box, handle: handle, to: local, lockAspect: false)
            let sx = box.width > 0 ? newBox.width / box.width : 1
            let sy = box.height > 0 ? newBox.height / box.height : 1
            let scaled = points.map {
                CGPoint(
                    x: newBox.minX + ($0.x - box.minX) * sx,
                    y: newBox.minY + ($0.y - box.minY) * sy
                )
            }
            copy.kind = .pen(points: scaled)
        case .text(_, let string, let fontSize):
            let box = localBounds
            let newBox = ShapeGeometry.resizedRect(box, handle: handle, to: local, lockAspect: false)
            let ratio: CGFloat
            switch handle {
            case .left, .right:
                ratio = box.width > 0 ? newBox.width / box.width : 1
            default:
                ratio = box.height > 0 ? newBox.height / box.height : 1
            }
            let newFontSize = max(10, fontSize * ratio)
            let pad = Annotation.textPadding(fontSize: newFontSize)
            let newOrigin = CGPoint(x: newBox.minX + pad.x, y: newBox.minY + pad.y)
            copy.kind = .text(origin: newOrigin, string: string, fontSize: newFontSize)
        case .arrow, .line, .counter, .callout, .eraser:
            break
        }
        return copy
    }

    func withEndpoint(_ handle: ShapeHandle, to point: CGPoint) -> Annotation {
        let local = toLocal(point)
        var copy = self
        switch kind {
        case .arrow(let from, let to, let control):
            switch handle {
            case .arrowStart:
                copy.kind = .arrow(from: local, to: to, control: control)
            case .arrowEnd:
                copy.kind = .arrow(from: from, to: local, control: control)
            case .arrowControl:
                copy.kind = .arrow(from: from, to: to, control: local)
            default:
                break
            }
        case .line(let from, let to):
            switch handle {
            case .lineStart:
                copy.kind = .line(from: local, to: to)
            case .lineEnd:
                copy.kind = .line(from: from, to: local)
            default:
                break
            }
        case .counter(let center, let value, _):
            if handle == .counterLeader {
                copy.kind = .counter(center: center, value: value, leader: local)
            }
        case .callout(let center, let value, let labelOrigin, let string, let fontSize):
            if handle == .counterLeader {
                copy.kind = .callout(
                    center: center,
                    value: value,
                    labelOrigin: local,
                    string: string,
                    fontSize: fontSize
                )
            } else if handle == .arrowEnd {
                copy.kind = .callout(
                    center: local,
                    value: value,
                    labelOrigin: labelOrigin,
                    string: string,
                    fontSize: fontSize
                )
            } else if handle == .rotate {
                copy.kind = .callout(
                    center: local,
                    value: value,
                    labelOrigin: labelOrigin,
                    string: string,
                    fontSize: fontSize
                )
            }
        default:
            break
        }
        return copy
    }

    func withColor(_ color: RGBAColor) -> Annotation {
        var copy = self
        copy.color = color
        return copy
    }

    func withLineWidth(_ width: CGFloat) -> Annotation {
        var copy = self
        copy.lineWidth = width
        if case .eraser(let points, _) = kind {
            copy.kind = .eraser(points: points, radius: max(2, width / 2))
        }
        return copy
    }

    func withFontSize(_ size: CGFloat) -> Annotation {
        var copy = self
        switch kind {
        case .text(let origin, let string, _):
            copy.kind = .text(origin: origin, string: string, fontSize: size)
        case .callout(let center, let value, let labelOrigin, let string, _):
            copy.kind = .callout(
                center: center,
                value: value,
                labelOrigin: labelOrigin,
                string: string,
                fontSize: size
            )
        default:
            break
        }
        return copy
    }

    func withPixelateBlock(_ block: CGFloat) -> Annotation {
        guard case .pixelate(let rect, _) = kind else { return self }
        var copy = self
        copy.kind = .pixelate(rect, block: block)
        return copy
    }

    func withBlurRadius(_ radius: CGFloat) -> Annotation {
        guard case .blur(let rect, _) = kind else { return self }
        var copy = self
        copy.kind = .blur(rect, radius: radius)
        return copy
    }

    func withText(_ string: String) -> Annotation {
        var copy = self
        switch kind {
        case .text(let origin, _, let fontSize):
            copy.kind = .text(origin: origin, string: string, fontSize: fontSize)
        case .callout(let center, let value, let labelOrigin, _, let fontSize):
            copy.kind = .callout(
                center: center,
                value: value,
                labelOrigin: labelOrigin,
                string: string,
                fontSize: fontSize
            )
        default:
            break
        }
        return copy
    }

    /// 按比例缩放整条标注（预览用）。
    func scaled(by factor: CGFloat) -> Annotation {
        func sp(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * factor, y: point.y * factor)
        }
        func sr(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX * factor,
                y: rect.minY * factor,
                width: rect.width * factor,
                height: rect.height * factor
            )
        }

        var copy = self
        switch kind {
        case .rectangle(let rect): copy.kind = .rectangle(sr(rect))
        case .ellipse(let rect): copy.kind = .ellipse(sr(rect))
        case .highlight(let rect): copy.kind = .highlight(sr(rect))
        case .pixelate(let rect, let block):
            copy.kind = .pixelate(sr(rect), block: max(2, block * factor))
        case .blur(let rect, let radius):
            copy.kind = .blur(sr(rect), radius: max(1, radius * factor))
        case .arrow(let from, let to, let control):
            copy.kind = .arrow(from: sp(from), to: sp(to), control: control.map(sp))
        case .line(let from, let to):
            copy.kind = .line(from: sp(from), to: sp(to))
        case .pen(let points): copy.kind = .pen(points: points.map(sp))
        case .text(let origin, let string, let size):
            copy.kind = .text(origin: sp(origin), string: string, fontSize: size * factor)
        case .counter(let center, let value, let leader):
            copy.kind = .counter(center: sp(center), value: value, leader: leader.map(sp))
        case .callout(let center, let value, let labelOrigin, let string, let size):
            copy.kind = .callout(
                center: sp(center),
                value: value,
                labelOrigin: sp(labelOrigin),
                string: string,
                fontSize: size * factor
            )
        case .eraser(let points, let radius):
            copy.kind = .eraser(points: points.map(sp), radius: radius * factor)
        }
        copy.lineWidth = lineWidth * factor
        return copy
    }

    private mutating func replaceRect(_ rect: CGRect) {
        switch kind {
        case .rectangle:
            kind = .rectangle(rect)
        case .ellipse:
            kind = .ellipse(rect)
        case .highlight:
            kind = .highlight(rect)
        case .pixelate:
            if case .pixelate(_, let block) = kind { kind = .pixelate(rect, block: block) }
        case .blur:
            if case .blur(_, let radius) = kind { kind = .blur(rect, radius: radius) }
        default:
            break
        }
    }

    private static func translateKind(_ kind: Kind, by delta: CGSize) -> Kind {
        func move(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + delta.width, y: point.y + delta.height)
        }
        func moveRect(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: delta.width, dy: delta.height) }
        switch kind {
        case .rectangle(let rect): return .rectangle(moveRect(rect))
        case .ellipse(let rect): return .ellipse(moveRect(rect))
        case .highlight(let rect): return .highlight(moveRect(rect))
        case .pixelate(let rect, let block): return .pixelate(moveRect(rect), block: block)
        case .blur(let rect, let radius): return .blur(moveRect(rect), radius: radius)
        case .arrow(let from, let to, let control):
            return .arrow(from: move(from), to: move(to), control: control.map(move))
        case .line(let from, let to): return .line(from: move(from), to: move(to))
        case .pen(let points): return .pen(points: points.map(move))
        case .text(let origin, let string, let fontSize):
            return .text(origin: move(origin), string: string, fontSize: fontSize)
        case .counter(let center, let value, let leader):
            return .counter(center: move(center), value: value, leader: leader.map(move))
        case .callout(let center, let value, let labelOrigin, let string, let fontSize):
            return .callout(
                center: move(center),
                value: value,
                labelOrigin: move(labelOrigin),
                string: string,
                fontSize: fontSize
            )
        case .eraser(let points, let radius):
            return .eraser(points: points.map(move), radius: radius)
        }
    }
}

// MARK: - 工具函数

extension Annotation {
    /// 标注气泡文字框的矩形（含内边距）。
    static func calloutLabelRect(origin: CGPoint, string: String, fontSize: CGFloat) -> CGRect {
        let size = textSize(string: string.isEmpty ? "文字" : string, fontSize: fontSize)
        return CGRect(
            origin: origin,
            size: CGSize(width: size.width + 16, height: max(fontSize * 1.6, size.height + 10))
        )
    }

    static func textPadding(fontSize: CGFloat) -> (x: CGFloat, y: CGFloat) {
        let px = max(6, ceil(fontSize * 0.15))
        let py = max(4, ceil(fontSize * 0.12))
        return (px, py)
    }

    static func systemFont(fontSize: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName(".AppleSystemUIFont" as CFString, fontSize, nil)
    }

    static func textSize(string: String, fontSize: CGFloat) -> CGSize {
        guard !string.isEmpty, fontSize > 0 else {
            return CGSize(width: 0, height: fontSize * 1.2)
        }
        let font = systemFont(fontSize: fontSize)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font]
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return CGSize(width: ceil(width), height: ceil(ascent + descent))
    }

    static func rotate(_ point: CGPoint, around center: CGPoint, by angle: CGFloat) -> CGPoint {
        guard angle != 0 else { return point }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let cosA = cos(angle)
        let sinA = sin(angle)
        return CGPoint(
            x: center.x + dx * cosA - dy * sinA,
            y: center.y + dx * sinA + dy * cosA
        )
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// 点到矩形**边框**的距离：边框上为 0，往框里 / 框外都越来越大。
    ///
    /// 注意不是 `rect.contains`：那是"在不在框里"，这里要的是"离那条线多远"。
    static func distanceToRectBorder(_ point: CGPoint, rect: CGRect) -> CGFloat {
        let outsideX = max(rect.minX - point.x, point.x - rect.maxX, 0)
        let outsideY = max(rect.minY - point.y, point.y - rect.maxY, 0)
        if outsideX > 0 || outsideY > 0 {
            return hypot(outsideX, outsideY)
        }
        // 在框里：到最近那条边的距离。
        return min(
            point.x - rect.minX,
            rect.maxX - point.x,
            point.y - rect.minY,
            rect.maxY - point.y
        )
    }

    /// 点到椭圆**边框**的距离：沿「中心 → 点」这条射线量，边框上为 0。
    static func distanceToEllipseBorder(_ point: CGPoint, rect: CGRect) -> CGFloat {
        let rx = rect.width / 2
        let ry = rect.height / 2
        guard rx > 0.001, ry > 0.001 else {
            return distance(point, CGPoint(x: rect.midX, y: rect.midY))
        }
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        let length = hypot(dx / rx, dy / ry)
        guard length > 0.0001 else { return max(rx, ry) }
        // 该方向上从中心到边界的距离（归一化空间里的边界点再映回真实坐标）。
        let border = hypot(rx * (dx / rx) / length, ry * (dy / ry) / length)
        return abs(hypot(dx, dy) - border)
    }

    static func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let lengthSquared = (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)
        guard lengthSquared > 0 else { return distance(point, a) }
        var t = ((point.x - a.x) * (b.x - a.x) + (point.y - a.y) * (b.y - a.y)) / lengthSquared
        t = min(1, max(0, t))
        let projection = CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
        return distance(point, projection)
    }

    static func distanceToPolyline(_ point: CGPoint, points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return points.first.map { distance(point, $0) } ?? .greatestFiniteMagnitude }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 0..<(points.count - 1) {
            best = min(best, distanceToSegment(point, points[index], points[index + 1]))
        }
        return best
    }

    static func distanceToCurve(
        _ point: CGPoint,
        from: CGPoint,
        to: CGPoint,
        control: CGPoint?
    ) -> CGFloat {
        guard let control else { return distanceToSegment(point, from, to) }
        var best = CGFloat.greatestFiniteMagnitude
        let steps = 24
        var previous = from
        for index in 1...steps {
            let t = CGFloat(index) / CGFloat(steps)
            let current = quadPoint(from, control, to, t)
            best = min(best, distanceToSegment(point, previous, current))
            previous = current
        }
        return best
    }

    static func quadPoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * a.x + 2 * mt * t * c.x + t * t * b.x,
            y: mt * mt * a.y + 2 * mt * t * c.y + t * t * b.y
        )
    }
}

/// 选中标注上的控制点。
///
/// @author ixxxxoooo
enum ShapeHandle: Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case rotate
    case arrowStart, arrowEnd, arrowControl
    case lineStart, lineEnd
    case counterLeader
}

/// 与选中/缩放相关的纯几何。
///
/// @author ixxxxoooo
enum ShapeGeometry {
    static func resizedRect(
        _ rect: CGRect,
        handle: ShapeHandle,
        to point: CGPoint,
        lockAspect: Bool
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .topLeft, .left, .bottomLeft: minX = point.x
        default: break
        }
        switch handle {
        case .topRight, .right, .bottomRight: maxX = point.x
        default: break
        }
        switch handle {
        case .topLeft, .top, .topRight: minY = point.y
        default: break
        }
        switch handle {
        case .bottomLeft, .bottom, .bottomRight: maxY = point.y
        default: break
        }

        if maxX < minX { swap(&minX, &maxX) }
        if maxY < minY { swap(&minY, &maxY) }

        let minimum: CGFloat = 6
        if maxX - minX < minimum { maxX = minX + minimum }
        if maxY - minY < minimum { maxY = minY + minimum }

        if lockAspect, rect.height > 0 {
            let ratio = rect.width / rect.height
            var width = maxX - minX
            var height = maxY - minY
            if width / height > ratio { width = height * ratio } else { height = width / ratio }
            if case .topLeft = handle { minX = maxX - width; minY = maxY - height }
            if case .topRight = handle { maxX = minX + width; minY = maxY - height }
            if case .bottomRight = handle { maxX = minX + width; maxY = minY + height }
            if case .bottomLeft = handle { minX = maxX - width; maxY = minY + height }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 矩形类标注的 8 个缩放控制点（世界坐标）。
    static func resizeHandles(for annotation: Annotation) -> [(ShapeHandle, CGPoint)] {
        let box = annotation.localBounds
        let points: [(ShapeHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: box.minX, y: box.minY)),
            (.top, CGPoint(x: box.midX, y: box.minY)),
            (.topRight, CGPoint(x: box.maxX, y: box.minY)),
            (.right, CGPoint(x: box.maxX, y: box.midY)),
            (.bottomRight, CGPoint(x: box.maxX, y: box.maxY)),
            (.bottom, CGPoint(x: box.midX, y: box.maxY)),
            (.bottomLeft, CGPoint(x: box.minX, y: box.maxY)),
            (.left, CGPoint(x: box.minX, y: box.midY)),
        ]
        return points.map { ($0.0, annotation.toWorld($0.1)) }
    }

    /// 旋转手柄（顶边中点上方）。
    static func rotateHandle(for annotation: Annotation, distance: CGFloat = 26) -> CGPoint {
        let box = annotation.localBounds
        return annotation.toWorld(CGPoint(x: box.midX, y: box.minY - distance))
    }
}
