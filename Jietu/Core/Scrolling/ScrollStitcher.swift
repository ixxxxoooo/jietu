import CoreGraphics
import Foundation

/// 滚动长图的拼接：用**行签名互相关**算出相邻两帧的纵向位移，再把新增的行接到长图下方。
///
/// 只依赖 CoreGraphics，可脱屏做像素级单测（见 `ScrollStitcherTests`）。
/// 所有几何量按图像像素坐标、原点左上处理。
///
/// @author ixxxxoooo
enum ScrollStitcher {
    /// 两帧至少要重叠这么多比例才算「接得上」。
    static let minimumOverlapRatio: CGFloat = 0.25
    /// 行签名每行最多采样多少个像素。
    static let signatureColumns = 64
    /// 匹配成功的平均通道误差阈值（0...255）。
    static let matchTolerance: Double = 14

    /// 单帧的行签名（每行 RGB 均值），用于计算位移。
    static func rowSignatures(_ image: CGImage) -> [[Double]]? {
        guard let buffer = rgbaBuffer(image), buffer.height > 1, buffer.width > 0 else { return nil }
        let columns = max(1, min(signatureColumns, buffer.width))
        let step = max(1, buffer.width / columns)

        var signatures: [[Double]] = []
        signatures.reserveCapacity(buffer.height)
        for row in 0..<buffer.height {
            var sum = [0.0, 0.0, 0.0]
            var count = 0
            let rowStart = row * buffer.bytesPerRow
            var column = 0
            while column < buffer.width {
                let offset = rowStart + column * 4
                sum[0] += Double(buffer.data[offset])
                sum[1] += Double(buffer.data[offset + 1])
                sum[2] += Double(buffer.data[offset + 2])
                count += 1
                column += step
            }
            let divisor = Double(max(1, count))
            signatures.append([sum[0] / divisor, sum[1] / divisor, sum[2] / divisor])
        }
        return signatures
    }

    /// 相邻两帧的纵向位移：内容向上移动了 `shift` 像素（即下一帧顶部出现了上一帧的第 shift 行）。
    ///
    /// 返回 nil 表示对不上——通常是滚动太快、内容跳动，或根本换了页面。
    static func offset(previous: CGImage, next: CGImage, maxShift: Int? = nil) -> Int? {
        guard let first = rowSignatures(previous), let second = rowSignatures(next) else { return nil }
        return offset(previousSignatures: first, nextSignatures: second, maxShift: maxShift)
    }

    /// 签名版本的位移计算（便于测试）。
    static func offset(
        previousSignatures: [[Double]],
        nextSignatures: [[Double]],
        maxShift: Int? = nil
    ) -> Int? {
        let height = previousSignatures.count
        guard height > 0, nextSignatures.count >= height else { return nil }
        let minimumOverlap = max(4, Int((CGFloat(height) * minimumOverlapRatio).rounded(.up)))
        let limit = min(maxShift ?? (height - minimumOverlap), height - minimumOverlap)
        guard limit >= 0 else { return nil }

        var best: (shift: Int, error: Double)?
        for shift in 0...limit {
            // 上一帧第 y 行 ↔ 下一帧第 y - shift 行。
            var total = 0.0
            for row in shift..<height {
                let a = previousSignatures[row]
                let b = nextSignatures[row - shift]
                total += abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])
            }
            let compared = Double((height - shift) * 3)
            let error = total / max(1, compared)
            if best == nil || error < best!.error {
                best = (shift, error)
            }
        }

        guard let best, best.error <= matchTolerance else { return nil }
        return best.shift
    }

    /// 把多帧拼成一张长图：帧序必须自上而下推进（场景内容向上滚动）。
    ///
    /// 注意 `previous` **只在拼接成功后前移**：`append` 取的是「相对长图末行」的位移，
    /// 参考帧必须是**已经拼进长图的那一帧**。若把「对不上而跳过」的帧当成参考帧，
    /// 下一帧算出来的位移就是相对一个从未拼进去的帧，结果会漏行 / 错位
    /// （典型场景：用户往回滚了一点，再继续向下滚）。
    static func stitch(_ frames: [CGImage]) -> CGImage? {
        guard var result = frames.first else { return nil }
        var previous = result
        for frame in frames.dropFirst() {
            guard let shift = offset(previous: previous, next: frame), shift > 0,
                let merged = append(base: result, next: frame, shift: shift)
            else { continue }
            result = merged
            previous = frame
        }
        return result
    }

    /// 在长图底部接上 `next` 的最后 `shift` 行。
    static func append(base: CGImage, next: CGImage, shift: Int) -> CGImage? {
        let width = base.width
        let added = min(shift, next.height)
        guard added > 0, width > 0, next.width == width else { return nil }

        let height = base.height + added
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.interpolationQuality = .none
        // 原点左下：底图放上方。
        context.draw(base, in: CGRect(x: 0, y: added, width: width, height: base.height))
        // 取下一帧的**底部** added 行（CGImage 裁剪用左上原点）。
        let strip = CGRect(x: 0, y: next.height - added, width: width, height: added)
        guard let bottom = next.cropping(to: strip) else { return nil }
        context.draw(bottom, in: CGRect(x: 0, y: 0, width: width, height: added))
        return context.makeImage()
    }

    // MARK: - Pixels

    private struct Buffer {
        let data: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    /// 把图像重绘到已知布局的 RGBA8 缓冲，避免依赖 CGImage 的原始位布局。
    private static func rgbaBuffer(_ image: CGImage) -> Buffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = data.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Buffer(data: data, width: width, height: height, bytesPerRow: bytesPerRow)
    }
}
