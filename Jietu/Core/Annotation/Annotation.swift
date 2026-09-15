import CoreGraphics
import Foundation

/// 标注工具种类。
///
/// @author ixxxxoooo
enum AnnotationTool: String, CaseIterable, Identifiable {
    case rectangle
    case ellipse
    case arrow
    case text
    case pixelate
    case counter

    var id: String { rawValue }

    /// 工具栏标题。
    var title: String {
        switch self {
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .text: return "文字"
        case .pixelate: return "马赛克"
        case .counter: return "序号"
        }
    }

    /// SF Symbol 名称。
    var symbolName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .pixelate: return "squareshape.split.3x3"
        case .counter: return "1.circle"
        }
    }
}

/// 与外观无关的 RGBA 颜色，便于脱离 SwiftUI 做纯逻辑测试。
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

    /// 工具栏可选的预设色。
    static let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .white, .black]
}

/// 一条标注。
///
/// 所有几何量都以**图像像素坐标**表示，原点左上，与 `CGImage` 对齐，
/// 避免在编辑（缩放显示）与导出（原图渲染）之间反复换算。
///
/// @author ixxxxoooo
struct Annotation: Identifiable, Equatable {
    enum Shape: Equatable {
        case rectangle(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
        case text(origin: CGPoint, string: String, fontSize: CGFloat)
        case pixelate(CGRect)
        case counter(center: CGPoint, value: Int)
    }

    let id: UUID
    var shape: Shape
    var color: RGBAColor
    var lineWidth: CGFloat

    init(
        id: UUID = UUID(),
        shape: Shape,
        color: RGBAColor,
        lineWidth: CGFloat = 3
    ) {
        self.id = id
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
    }
}

extension Annotation {
    /// 按比例缩放整条标注。
    ///
    /// 用途：编辑器在**降采样预览图**上渲染，而导出在**原图**上渲染；
    /// 预览时把标注从图像坐标缩到预览坐标即可复用同一个渲染器，保证所见即所得。
    func scaled(by factor: CGFloat) -> Annotation {
        func scalePoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * factor, y: point.y * factor)
        }
        func scaleRect(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX * factor,
                y: rect.minY * factor,
                width: rect.width * factor,
                height: rect.height * factor
            )
        }

        var copy = self
        switch shape {
        case .rectangle(let rect):
            copy.shape = .rectangle(scaleRect(rect))
        case .ellipse(let rect):
            copy.shape = .ellipse(scaleRect(rect))
        case .arrow(let from, let to):
            copy.shape = .arrow(from: scalePoint(from), to: scalePoint(to))
        case .text(let origin, let string, let fontSize):
            copy.shape = .text(origin: scalePoint(origin), string: string, fontSize: fontSize * factor)
        case .pixelate(let rect):
            copy.shape = .pixelate(scaleRect(rect))
        case .counter(let center, let value):
            copy.shape = .counter(center: scalePoint(center), value: value)
        }
        copy.lineWidth = lineWidth * factor
        return copy
    }
}
