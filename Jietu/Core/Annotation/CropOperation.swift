import CoreGraphics
import Foundation

/// 截后再裁剪的纯计算：把裁剪框夹进图像范围，裁底图，
/// 并把已有标注 / 擦除笔迹平移到新原点。
///
/// @author ixxxxoooo
enum CropOperation {
    /// 裁剪结果：新底图 + 实际生效的裁剪框（已夹取整）。
    struct Result {
        let image: CGImage
        let rect: CGRect
    }

    /// 裁剪框的最小边长（像素），太小视为误操作。
    static let minimumSide: CGFloat = 4

    /// 把裁剪框夹进图像范围并取整；无效或过小返回 nil。
    static func clampedRect(_ rect: CGRect, imageSize: CGSize) -> CGRect? {
        let bounds = CGRect(origin: .zero, size: imageSize)
        let clamped = rect.intersection(bounds).integral
        guard clamped.width >= minimumSide, clamped.height >= minimumSide else { return nil }
        return clamped
    }

    static func crop(_ image: CGImage, to rect: CGRect) -> Result? {
        let size = CGSize(width: image.width, height: image.height)
        guard let clamped = clampedRect(rect, imageSize: size),
            let cropped = image.cropping(to: clamped)
        else { return nil }
        return Result(image: cropped, rect: clamped)
    }

    /// 裁剪后把标注移到新坐标系（减去裁剪框原点）。
    static func shifted(_ annotations: [Annotation], by delta: CGSize) -> [Annotation] {
        annotations.map { $0.translated(by: delta) }
    }

    /// 擦除笔迹同样要跟着走，否则裁完会「擦错位置」。
    static func shifted(_ strokes: [EraserStroke], by delta: CGSize) -> [EraserStroke] {
        strokes.map { stroke in
            EraserStroke(
                points: stroke.points.map {
                    CGPoint(x: $0.x + delta.width, y: $0.y + delta.height)
                },
                radius: stroke.radius
            )
        }
    }

    /// 裁剪框原点取负，即旧坐标 → 新坐标的平移量。
    static func offset(for rect: CGRect) -> CGSize {
        CGSize(width: -rect.minX, height: -rect.minY)
    }
}
