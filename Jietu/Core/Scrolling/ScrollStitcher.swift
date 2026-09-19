import CoreGraphics
import Foundation
import Vision

/// 滚动长图拼接引擎：参考 capcap 最佳实践。
///
/// 核心特性：
/// 1. **Apple Vision 2D 图像配准** (`VNTranslationalImageRegistrationRequest`)：
///    将两帧作为 2D 连续信号进行空间配准，杜绝 1D 行平均签名在低纹理、相似字行与空白处的误判。
/// 2. **吸顶栏与滚动条检测与剔除**：
///    自动检测顶部吸顶导航栏与右侧滚动条并剔除，确保 Vision 只对真正移动的页面主体进行对齐；
/// 3. **高速内存切片拼接 (`memcpy`)**：
///    避免每拍重建 CGContext 绘制整张底图的 O(N^2) 内存与 CPU 浪费，单趟生成最终高分辨率长图；
/// 4. **行签名互相关兜底**：
///    当 Vision 无法获取特征时回退到行签名。
///
/// @author ixxxxoooo
enum ScrollStitcher {
    /// 两帧至少要重叠这么多比例才算「接得上」。
    static let minimumOverlapRatio: CGFloat = 0.25
    /// 行签名每行最多采样多少个像素。
    static let signatureColumns = 64
    /// 匹配成功的平均通道误差阈值（0...255）。
    static let matchTolerance: Double = 14

    // MARK: - 高性能位图数据

    final class BitmapData {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        var data: [UInt8]

        init?(image: CGImage) {
            self.width = image.width
            self.height = image.height
            guard width > 0, height > 0 else { return nil }
            self.bytesPerRow = width * 4
            self.data = [UInt8](repeating: 0, count: bytesPerRow * height)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: &data,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            self.bytesPerRow = width * 4
            self.data = [UInt8](repeating: 0, count: bytesPerRow * height)
        }

        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            guard x >= 0, x < width, y >= 0, y < height else { return (0, 0, 0) }
            let offset = y * bytesPerRow + x * 4
            return (data[offset], data[offset + 1], data[offset + 2])
        }

        func makeCGImage(pixelHeight: Int? = nil) -> CGImage? {
            makeCGImage(pixelRange: 0..<(pixelHeight ?? height))
        }

        /// 取**某几行**（行号自上而下、区间左闭右开）变成一张图。预览按增量画新内容时用它。
        func makeCGImage(pixelRange: Range<Int>) -> CGImage? {
            let start = max(0, pixelRange.lowerBound)
            let end = min(height, pixelRange.upperBound)
            let h = end - start
            guard h > 0 else { return nil }
            let offset = start * bytesPerRow
            let byteCount = h * bytesPerRow
            guard
                let cfData = CFDataCreate(
                    kCFAllocatorDefault, Array(data[offset..<(offset + byteCount)]), byteCount
                ),
                let provider = CGDataProvider(data: cfData)
            else { return nil }
            return CGImage(
                width: width,
                height: h,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }

        func copyRows(from source: BitmapData, sourceStartRow: Int, rowCount: Int, destinationStartRow: Int) {
            guard rowCount > 0 else { return }
            let rowBytes = min(width * 4, source.width * 4)
            data.withUnsafeMutableBytes { dstPtr in
                source.data.withUnsafeBytes { srcPtr in
                    guard let dstBase = dstPtr.baseAddress, let srcBase = srcPtr.baseAddress else { return }
                    for r in 0..<rowCount {
                        let srcOff = (sourceStartRow + r) * source.bytesPerRow
                        let dstOff = (destinationStartRow + r) * bytesPerRow
                        memcpy(dstBase + dstOff, srcBase + srcOff, rowBytes)
                    }
                }
            }
        }

        func isNearlyIdentical(to other: BitmapData) -> Bool {
            guard width == other.width, height == other.height else { return false }
            let numCols = min(32, max(16, width / 20))
            let numRows = min(32, max(16, height / 20))
            let cols = Self.sampledIndices(length: width, count: numCols, inset: min(max(4, width / 12), max(4, width / 4)))
            let rows = Self.sampledIndices(length: height, count: numRows, inset: 4)

            var totalDiff = 0
            var count = 0
            for r in rows {
                for c in cols {
                    let p1 = pixel(x: c, y: r)
                    let p2 = other.pixel(x: c, y: r)
                    totalDiff += abs(Int(p1.r) - Int(p2.r)) + abs(Int(p1.g) - Int(p2.g)) + abs(Int(p1.b) - Int(p2.b))
                    count += 1
                }
            }
            guard count > 0 else { return false }
            return (totalDiff / count) < 3
        }

        private static func sampledIndices(length: Int, count: Int, inset: Int) -> [Int] {
            guard length > 0, count > 0 else { return [] }
            let lower = min(length - 1, inset)
            let upper = max(lower, length - inset - 1)
            let span = max(1, upper - lower + 1)
            var res: [Int] = []
            res.reserveCapacity(count)
            for i in 0..<count {
                let val = lower + min(span - 1, span * (i * 2 + 1) / max(1, count * 2))
                if res.last != val { res.append(val) }
            }
            return res
        }
    }

    // MARK: - 静态辅助方法（兼容已有接口与单测）

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

    static func offset(previous: CGImage, next: CGImage, maxShift: Int? = nil) -> Int? {
        // 先尝试 Vision 配准
        let req = VNTranslationalImageRegistrationRequest(targetedCGImage: previous)
        let handler = VNImageRequestHandler(cgImage: next, options: [:])
        if (try? handler.perform([req])) != nil,
           let obs = req.results?.first as? VNImageTranslationAlignmentObservation {
            let ty = obs.alignmentTransform.ty
            let shift = Int(ty.rounded())
            if shift >= 0 && shift < next.height {
                if shift == 0 {
                    return 0
                }
                if verifyOffset(shift: shift, previous: previous, next: next) {
                    if let maxShift, shift > maxShift {
                        // 超出限制
                    } else {
                        return shift
                    }
                }
            }
        }

        // 回退到行签名
        guard let first = rowSignatures(previous), let second = rowSignatures(next) else { return nil }
        return offset(previousSignatures: first, nextSignatures: second, maxShift: maxShift)
    }

    static func verifyOffset(shift: Int, previous: CGImage, next: CGImage) -> Bool {
        guard let b1 = BitmapData(image: previous), let b2 = BitmapData(image: next) else { return false }
        let overlap = min(previous.height - shift, next.height)
        guard overlap >= 4 else { return false }
        let sampleStep = max(1, overlap / 20)
        let colStep = max(1, min(b1.width, b2.width) / 10)

        var diff = 0.0
        var count = 0
        var r = 0
        while r < overlap {
            var c = 0
            while c < min(b1.width, b2.width) {
                let p1 = b1.pixel(x: c, y: shift + r)
                let p2 = b2.pixel(x: c, y: r)
                diff += Double(abs(Int(p1.r) - Int(p2.r)) + abs(Int(p1.g) - Int(p2.g)) + abs(Int(p1.b) - Int(p2.b)))
                count += 1
                c += colStep
            }
            r += sampleStep
        }
        guard count > 0 else { return false }
        return (diff / Double(count * 3)) <= matchTolerance
    }

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

    static func stitch(_ frames: [CGImage]) -> CGImage? {
        guard let first = frames.first else { return nil }
        if frames.count == 1 { return first }
        let session = Session(firstFrame: first, maxFrames: max(100, frames.count + 10))
        for frame in frames.dropFirst() {
            _ = session.append(frame: frame)
        }
        return session.finish()
    }

    static func append(base: CGImage, next: CGImage, shift: Int) -> CGImage? {
        let width = base.width
        let added = min(shift, next.height)
        guard added > 0, width > 0, next.width == width else { return nil }

        guard let bBase = BitmapData(image: base), let bNext = BitmapData(image: next) else { return nil }
        let output = BitmapData(width: width, height: base.height + added)
        output.copyRows(from: bBase, sourceStartRow: 0, rowCount: base.height, destinationStartRow: 0)
        output.copyRows(from: bNext, sourceStartRow: next.height - added, rowCount: added, destinationStartRow: base.height)
        return output.makeCGImage()
    }

    struct Buffer {
        let data: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    static func rgbaBuffer(_ image: CGImage) -> Buffer? {
        guard let bitmap = BitmapData(image: image) else { return nil }
        return Buffer(data: bitmap.data, width: bitmap.width, height: bitmap.height, bytesPerRow: bitmap.bytesPerRow)
    }
}

