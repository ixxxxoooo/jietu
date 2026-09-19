import AppKit
import os
import Vision

/// 滚动拼接 — 会话管理器（有状态部分）。
///
/// @author ixxxxoooo
extension ScrollStitcher {

    final class Session {
        enum FrameOutcome: Equatable {
            case appended(newHeight: Int)
            case noNewContent
            case atLimit
        }

        private(set) var frames: [CGImage] = []
        private(set) var bitmaps: [BitmapData] = []
        private(set) var overlaps: [Int] = []

        var scrollbarWidthPx: Int = 0
        var scrollbarDetected: Bool = false
        var stickyHeaderPx: Int = 0
        var stickyHeaderDetectionDone: Bool = false
        var stickyHeaderSamplesTaken: Int = 0

        private(set) var currentHeight: Int = 0
        let maxFrames: Int
        let maxPixelHeight: Int

        /// 预览画布：**小尺寸、定比例、只保留最新一段**。
        ///
        /// 以前是把整张长图交给 SwiftUI 去缩放：图越长每帧重采样的像素越多（滚一会儿就卡），
        /// 而且 `.fit` 会把长图越缩越细，最后只剩一条竖线。现在按「面板像素尺寸」定比例，
        /// 每拍只把**新增的那几行**画进去、旧内容整体上移一格：开销与长图总长无关，
        /// 全程流畅，看到的也总是刚滚出来的内容。
        /// 自动滚动时**已知的每帧位移**（像素）：先用它算重叠、校验通过就不跑 Vision。
        ///
        /// 位移是我们自己发出去的（步长 × 缩放），Vision 那一下要 20~45ms/帧，
        /// 那才是自动滚动一顿一顿的来源（自检 `--selftest-scroll-cost` 量过）。
        /// 校验不过（页面滑到头 / 吸附、惯性滚动）就照旧回退到 Vision，正确性不变。
        var expectedShiftPixels: Int = 0

        private let previewPixelSize: CGSize
        private var previewContext: CGContext?
        private var previewScale: CGFloat = 1
        private var previewCanvas = CGSize.zero
        /// 画布上已经码到哪一行（缩放后）：内容从顶部往下码，满了整体上移一格。
        private var previewFilledRows: CGFloat = 0

        init(
            firstFrame: CGImage,
            maxFrames: Int = 120,
            maxPixelHeight: Int = 25_000,
            previewPixelSize: CGSize = .zero
        ) {
            self.maxFrames = maxFrames
            self.maxPixelHeight = maxPixelHeight
            self.previewPixelSize = previewPixelSize
            guard let firstBitmap = BitmapData(image: firstFrame) else {
                self.currentHeight = firstFrame.height
                return
            }
            frames.append(firstFrame)
            bitmaps.append(firstBitmap)
            currentHeight = firstFrame.height
            initPreview(firstBitmap)
        }

        func append(frame: CGImage) -> FrameOutcome {
            guard frames.count < maxFrames, currentHeight < maxPixelHeight else {
                return .atLimit
            }
            guard let currentBitmap = BitmapData(image: frame),
                  let prevBitmap = bitmaps.last,
                  let prevCG = frames.last else {
                return .noNewContent
            }

            if prevBitmap.isNearlyIdentical(to: currentBitmap) {
                return .noNewContent
            }

            if !scrollbarDetected {
                detectScrollbar(current: currentBitmap, previous: prevBitmap)
            }

            let overlap = hintedOverlap(current: currentBitmap, previous: prevBitmap)
                ?? findOverlap(
                    previous: prevBitmap, previousCG: prevCG,
                    current: currentBitmap, currentCG: frame
                )
            let newRows = currentBitmap.height - overlap
            let minimumNewRows = max(4, currentBitmap.height / 200)
            guard newRows >= minimumNewRows else {
                return .noNewContent
            }

            frames.append(frame)
            bitmaps.append(currentBitmap)
            overlaps.append(overlap)
            currentHeight += newRows
            appendToPreview(currentBitmap, overlapPixels: overlap)
            return .appended(newHeight: currentHeight)
        }

        /// 右侧预览：最新一段的**小图**（尺寸恒定，与长图总长无关）。
        func currentPreviewImage() -> CGImage? {
            guard let previewContext else { return frames.first }
            return previewContext.makeImage()
        }

        func finish() -> CGImage? {
            guard !frames.isEmpty else { return nil }
            if frames.count == 1 { return frames[0] }

            guard let firstBitmap = bitmaps.first else { return frames.first }
            let totalHeight = overlaps.reduce(firstBitmap.height) { partial, overlap in
                partial + (firstBitmap.height - overlap)
            }
            let output = BitmapData(width: firstBitmap.width, height: totalHeight)

            var dstRow = 0
            for i in frames.indices {
                let bitmap = bitmaps[i]
                let srcStart = i == 0 ? 0 : overlaps[i - 1]
                let count = bitmap.height - srcStart
                output.copyRows(from: bitmap, sourceStartRow: srcStart, rowCount: count, destinationStartRow: dstRow)
                dstRow += count
            }
            return output.makeCGImage()
        }

        private func initPreview(_ first: BitmapData) {
            guard previewPixelSize.width > 1, previewPixelSize.height > 1 else { return }
            let canvasWidth = Int(previewPixelSize.width.rounded())
            let canvasHeight = Int(previewPixelSize.height.rounded())
            previewScale = CGFloat(canvasWidth) / CGFloat(max(1, first.width))
            previewCanvas = CGSize(width: canvasWidth, height: canvasHeight)
            guard
                let context = CGContext(
                    data: nil,
                    width: canvasWidth,
                    height: canvasHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return }
            context.interpolationQuality = .low
            // 翻成「行从上往下」的坐标系：后面按行号算 y 就不会搞反。
            context.translateBy(x: 0, y: CGFloat(canvasHeight))
            context.scaleBy(x: 1, y: -1)
            previewContext = context
            drawPreview(slice: first, fromRow: 0, rows: first.height)
        }

        /// 把 `slice` 的某几行画进预览画布（按 `previewScale` 缩放）。
        ///
        /// 定位规则：内容从**顶部**往下码，码满之后整体上移一格——所以早期不留缝、
        /// 后来也总是「最新的一段在底部」。
        private func drawPreview(slice: BitmapData, fromRow: Int, rows: Int) {
            guard let context = previewContext, rows > 0 else { return }
            guard let image = slice.makeCGImage(pixelRange: fromRow..<(fromRow + rows)) else {
                return
            }
            let scaledHeight = CGFloat(rows) * previewScale
            // 装不下了：先把已有内容整体上移「溢出」那么多，最老的一段被挤出去。
            let overflow = previewFilledRows + scaledHeight - previewCanvas.height
            if overflow > 0 {
                if let snapshot = context.makeImage() {
                    context.clear(CGRect(origin: .zero, size: previewCanvas))
                    context.draw(
                        snapshot,
                        in: CGRect(
                            x: 0, y: -overflow,
                            width: previewCanvas.width, height: previewCanvas.height
                        )
                    )
                }
                previewFilledRows = max(0, previewFilledRows - overflow)
            }
            context.draw(
                image,
                in: CGRect(
                    x: 0, y: previewFilledRows,
                    width: previewCanvas.width, height: scaledHeight
                )
            )
            previewFilledRows = min(previewCanvas.height, previewFilledRows + scaledHeight)
        }

        private func appendToPreview(_ bitmap: BitmapData, overlapPixels: Int) {
            let newRows = bitmap.height - overlapPixels
            guard newRows > 0 else { return }
            drawPreview(slice: bitmap, fromRow: overlapPixels, rows: newRows)
        }

        private func detectScrollbar(current: BitmapData, previous: BitmapData) {
            defer { scrollbarDetected = true }
            let width = min(current.width, previous.width)
            let height = min(current.height, previous.height)
            guard width > 80, height > 40 else { return }

            let maxScan = min(50, width / 8)
            let sampleStart = height / 5
            let sampleEnd = (height * 4) / 5
            let sampleStep = max(1, (sampleEnd - sampleStart) / 30)

            var detectedWidth = 0
            var sawQuietAfterMoving = false

            for offset in 0..<maxScan {
                let column = width - 1 - offset
                var totalDiff = 0
                var samples = 0
                var row = sampleStart
                while row < sampleEnd {
                    let lhs = current.pixel(x: column, y: row)
                    let rhs = previous.pixel(x: column, y: row)
                    totalDiff += abs(Int(lhs.r) - Int(rhs.r)) + abs(Int(lhs.g) - Int(rhs.g)) + abs(Int(lhs.b) - Int(rhs.b))
                    samples += 1
                    row += sampleStep
                }
                guard samples > 0 else { continue }
                let avg = totalDiff / samples
                if avg > 8 {
                    detectedWidth = offset + 1
                } else if detectedWidth > 0 {
                    sawQuietAfterMoving = true
                    break
                }
            }

            if sawQuietAfterMoving && detectedWidth >= 3 && detectedWidth <= 40 {
                scrollbarWidthPx = detectedWidth + 4
            }
        }

        private func detectStickyHeader(current: BitmapData, previous: BitmapData) {
            let width = min(current.width, previous.width)
            let height = min(current.height, previous.height)
            guard width >= 40, height >= 30 else {
                stickyHeaderDetectionDone = true
                return
            }

            let scanWidth = max(40, width - scrollbarWidthPx)
            let columnStart = width / 10
            let columnEnd = min(scanWidth - 1, (scanWidth * 9) / 10)
            let columnStep = max(1, (columnEnd - columnStart) / 20)

            var firstMovingRow = -1
            for row in 0..<height {
                var totalDiff = 0
                var samples = 0
                var col = columnStart
                while col <= columnEnd {
                    let lhs = current.pixel(x: col, y: row)
                    let rhs = previous.pixel(x: col, y: row)
                    totalDiff += abs(Int(lhs.r) - Int(rhs.r)) + abs(Int(lhs.g) - Int(rhs.g)) + abs(Int(lhs.b) - Int(rhs.b))
                    samples += 1
                    col += columnStep
                }
                guard samples > 0 else { continue }
                if totalDiff / samples > 8 {
                    firstMovingRow = row
                    break
                }
            }

            guard firstMovingRow >= 0 else { return }

            let frozenRows = firstMovingRow
            let maxPlausibleHeader = (height * 6) / 10

            stickyHeaderSamplesTaken += 1
            if frozenRows < 8 || frozenRows > maxPlausibleHeader {
                stickyHeaderPx = 0
                stickyHeaderDetectionDone = true
                return
            }

            if stickyHeaderSamplesTaken == 1 {
                stickyHeaderPx = frozenRows
            } else if abs(frozenRows - stickyHeaderPx) <= 5 {
                stickyHeaderPx = min(stickyHeaderPx, frozenRows)
            } else {
                stickyHeaderPx = 0
                stickyHeaderDetectionDone = true
                return
            }

            if stickyHeaderSamplesTaken >= 2 {
                stickyHeaderDetectionDone = true
            }
        }

        /// 用「已知步长」直接算重叠，再用行签名校验；对得上就返回重叠行数，否则 nil（交给 Vision）。
        private func hintedOverlap(current: BitmapData, previous: BitmapData) -> Int? {
            let shift = expectedShiftPixels
            guard shift > 0, current.width == previous.width else { return nil }
            let tolerance = max(2, shift / 8)
            for candidate in [shift, shift - tolerance, shift + tolerance] where candidate > 0 {
                let overlap = current.height - candidate
                guard overlap > 0, overlap < min(current.height, previous.height) else { continue }
                if rowsMatch(previous: previous, current: current, overlap: overlap) {
                    return overlap
                }
            }
            return nil
        }

        /// 抽几行几列比一下：`current` 开头那 `overlap` 行，应当等于 `previous` **结尾**的 `overlap` 行。
        ///
        /// 方向别搞反：`overlap` 是「新帧开头有多少行已经在长图里了」（= 上一帧的尾巴），
        /// 所以上一帧要从 `height - overlap` 起比，不是从 `overlap` 起。
        private func rowsMatch(previous: BitmapData, current: BitmapData, overlap: Int) -> Bool {
            let rows = min(overlap, current.height)
            let base = previous.height - overlap
            guard rows > 4, base >= 0 else { return false }
            let columnStep = max(1, current.width / min(24, current.width))
            var total = 0
            var count = 0
            for index in 0..<6 {
                let row = min(rows - 1, rows * (index * 2 + 1) / 12)
                var column = 0
                while column < current.width {
                    let lhs = previous.pixel(x: column, y: base + row)
                    let rhs = current.pixel(x: column, y: row)
                    total += abs(Int(lhs.r) - Int(rhs.r)) + abs(Int(lhs.g) - Int(rhs.g))
                        + abs(Int(lhs.b) - Int(rhs.b))
                    count += 3
                    column += columnStep
                }
            }
            guard count > 0 else { return false }
            return Double(total) / Double(count) < 4
        }

        private func findOverlap(
            previous: BitmapData,
            previousCG: CGImage,
            current: BitmapData,
            currentCG: CGImage
        ) -> Int {
            let height = min(previous.height, current.height)
            guard height > 0 else { return 0 }

            if !scrollbarDetected {
                detectScrollbar(current: current, previous: previous)
            }
            if !stickyHeaderDetectionDone {
                detectStickyHeader(current: current, previous: previous)
            }

            let commonWidth = min(currentCG.width, previousCG.width)
            let commonHeight = min(currentCG.height, previousCG.height)
            let cropWidth = max(0, commonWidth - scrollbarWidthPx)
            let cropY = stickyHeaderPx > 0
                ? min(stickyHeaderPx, (commonHeight * 6) / 10)
                : 0
            let cropHeight = commonHeight - cropY

            var visionOffset: Int?
            if cropWidth >= 30 && cropHeight >= 30 {
                let cropRect = CGRect(x: 0, y: cropY, width: cropWidth, height: cropHeight)
                if let prevCropped = previousCG.cropping(to: cropRect),
                   let currCropped = currentCG.cropping(to: cropRect) {
                    let req = VNTranslationalImageRegistrationRequest(targetedCGImage: prevCropped)
                    let handler = VNImageRequestHandler(cgImage: currCropped, options: [:])
                    if (try? handler.perform([req])) != nil,
                       let obs = req.results?.first as? VNImageTranslationAlignmentObservation {
                        let ty = obs.alignmentTransform.ty
                        let shift = Int(ty.rounded())
                        if shift > 0 && shift < height {
                            visionOffset = shift
                        }
                    }
                }
            }

            if let shift = visionOffset {
                return height - shift
            }

            // 回退到签名计算
            if let sigShift = ScrollStitcher.offset(previous: previousCG, next: currentCG), sigShift > 0 {
                return height - sigShift
            }

            return height
        }
    }

}
