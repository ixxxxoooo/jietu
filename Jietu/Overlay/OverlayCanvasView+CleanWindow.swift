import AppKit

/// 遮罩画布 — 窗口截图的「干净窗口」。
///
/// 冻结画面是整屏的一张照片：目标窗口要是被别的窗口压住一块，照片里那一块就是
/// 压在上面的窗口。点中窗口后按窗口号独立截取一份干净的窗口画面（无视遮挡），
/// 盖到冻结画面的对应位置，编辑时看到的和最终保存的就都是用户点中的那个窗口。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    /// 异步截取 `window` 的干净画面并换进冻结画面；截取失败 / 用户已改动选区就保持原样。
    func replaceWithCleanWindow(_ window: WindowInfo) {
        guard let provider = cleanWindowProvider else { return }
        let expectedSelection = selection
        Task { @MainActor [weak self] in
            guard let image = await provider(window) else { return }
            guard let self, phase == .annotating, selection == expectedSelection else { return }
            let frame = DisplayGeometry.localRect(
                fromCGRect: window.frameInCGPoints, screen: screen
            )
            applyCleanWindow(image, windowFrameInView: frame)
        }
    }

    /// 把 `image`（窗口自己的画面）画到冻结画面里 `windowFrameInView`（view 坐标，原点左下）的位置。
    ///
    /// 窗口伸出屏幕的部分会被画布自然裁掉；窗口带透明圆角的地方保留底下的像素。
    func applyCleanWindow(_ image: CGImage, windowFrameInView frame: CGRect) {
        let base = snapshot.image
        let scale = snapshot.effectiveScale
        let space: CGColorSpace = {
            if let space = base.colorSpace, space.model == .rgb { return space }
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }()
        guard
            let context = CGContext(
                data: nil,
                width: base.width,
                height: base.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return }

        context.interpolationQuality = .none
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        // 位图上下文与 view 一样是左下原点，直接按 point × 缩放落位。
        context.draw(
            image,
            in: CGRect(
                x: frame.minX * scale, y: frame.minY * scale,
                width: frame.width * scale, height: frame.height * scale
            )
        )
        guard let composed = context.makeImage() else { return }

        snapshot = DisplaySnapshot(
            displayID: snapshot.displayID,
            screenFrameInPoints: snapshot.screenFrameInPoints,
            nominalScaleFactor: snapshot.nominalScaleFactor,
            image: composed
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = composed
        CATransaction.commit()

        preparePreviewBase()
        updateAnnotationLayer()
        updateLiveTextOverlay()
    }
}
