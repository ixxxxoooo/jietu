import CoreGraphics
import CoreText
import Foundation

/// 标注工具。
///
/// @author ixxxxoooo
enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case rectangle
    case ellipse
    case arrow
    case pen
    case highlight
    case text
    case pixelate
    case counter
    case eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "选择"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .highlight: return "高亮"
        case .text: return "文字"
        case .pixelate: return "马赛克"
        case .counter: return "序号"
        case .eraser: return "橡皮"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "squareshape.split.3x3"
        case .counter: return "1.circle"
        case .eraser: return "eraser"
        }
    }

    /// 是否为「绘制/动作类」工具（选择工具不是）。
    var isDrawing: Bool { self != .select }
}

/// 与外观无关的 RGBA 颜色。
///
/// @author ixxxxoooo
struct RGBAColor: Equatable, Hashable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
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
        case pen(points: [CGPoint])
        case highlight(CGRect)
        case text(origin: CGPoint, string: String, fontSize: CGFloat)
        case pixelate(CGRect, block: CGFloat)
        case counter(center: CGPoint, value: Int, leader: CGPoint?)
        /// 标注气泡：序号圆点 + 箭头 + 可输入说明的文字框。
        case callout(center: CGPoint, value: Int, labelOrigin: CGPoint, string: String, fontSize: CGFloat)
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
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect), .pixelate(let rect, _):
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
            return CGRect(origin: origin, size: size)
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
        case .rectangle(let rect), .ellipse(let rect), .highlight(let rect):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(local)
        case .pixelate(let rect, _):
            return rect.contains(local)
        case .arrow(let from, let to, let control):
            return Annotation.distanceToCurve(local, from: from, to: to, control: control)
                <= max(tolerance, lineWidth)
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
        case .rectangle, .ellipse, .highlight, .pixelate:
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
        case .text(let origin, let string, let fontSize):
            let box = localBounds
            let newBox = ShapeGeometry.resizedRect(box, handle: handle, to: local, lockAspect: false)
            let ratio = box.height > 0 ? newBox.height / box.height : 1
            copy.kind = .text(origin: newBox.origin, string: string, fontSize: max(10, fontSize * ratio))
        case .arrow, .counter, .callout:
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
        case .counter(let center, let value, let leader):
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
        case .arrow(let from, let to, let control):
            copy.kind = .arrow(from: sp(from), to: sp(to), control: control.map(sp))
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
        case .arrow(let from, let to, let control):
            return .arrow(from: move(from), to: move(to), control: control.map(move))
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

    static func textSize(string: String, fontSize: CGFloat) -> CGSize {
        guard !string.isEmpty, fontSize > 0 else {
            return CGSize(width: 0, height: fontSize * 1.2)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font]
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return CGSize(width: width, height: ascent + descent)
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
