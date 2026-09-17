import AppKit
import CoreGraphics

/// 窗口截图特效：窗口圆角裁切与 macOS 拟物多层柔和阴影渲染。
///
/// 对标 macOS 窗口管理器与 capcap / CleanShot X 的窗口截图渲染标准。
///
/// @author ixxxxoooo
enum WindowEffects {
    /// 阴影层配置（macOS 拟物窗口阴影由接触阴影、扩散阴影与环境柔光阴影复合而成）。
    struct ShadowLayer: Sendable, Equatable {
        let blur: CGFloat
        let offsetY: CGFloat
        let opacity: CGFloat
    }

    /// 根据阴影总大小计算复合阴影层。
    static func shadowLayers(forSize size: CGFloat) -> [ShadowLayer] {
        guard size > 0 else { return [] }
        return [
            // 1. 紧贴窗口边缘的接触阴影（近距、清晰、遮光感强）
            ShadowLayer(blur: size * 0.22, offsetY: size * 0.12, opacity: 0.18),
            // 2. 中距漫反射投影（形成主要体积感与浮空高度）
            ShadowLayer(blur: size * 0.55, offsetY: size * 0.35, opacity: 0.22),
            // 3. 远距大范围柔和环境光晕（自然融入任何浅色/深色背景）
            ShadowLayer(blur: size * 1.15, offsetY: size * 0.65, opacity: 0.14),
        ]
    }

    /// 计算所有阴影层需要的四周外扩留白（Shadow Outsets）。
    static func shadowOutsets(forSize size: CGFloat) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        guard size > 0 else { return (0, 0, 0, 0) }
        let horizontal = ceil(size * 1.4)
        let top = ceil(size * 0.8)
        let bottom = ceil(size * 2.0)
        return (left: horizontal, right: horizontal, top: top, bottom: bottom)
    }

    /// 为窗口图像应用原生圆角（默认 10pt，约等于 macOS 标准应用窗口角半径）。
    static func roundedCorners(
        image: CGImage,
        radiusPoints: CGFloat = 10,
        scale: CGFloat = 2
    ) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }

        let radius = max(0, radiusPoints * scale)
        guard radius > 0 else { return image }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return image
        }

        let path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.clip()
        context.draw(image, in: bounds)

        return context.makeImage() ?? image
    }

    /// 为带圆角的窗口添加 macOS 风格自然浮空投影，输出带透明背景的最终图像。
    static func withShadow(
        image: CGImage,
        shadowSize: CGFloat = 32,
        cornerRadiusPoints: CGFloat = 10,
        scale: CGFloat = 2
    ) -> CGImage {
        guard shadowSize > 0 else { return image }

        let imgWidth = CGFloat(image.width)
        let imgHeight = CGFloat(image.height)
        guard imgWidth > 0, imgHeight > 0 else { return image }

        let outsets = shadowOutsets(forSize: shadowSize)
        let outLeft = outsets.left * scale
        let outRight = outsets.right * scale
        let outTop = outsets.top * scale
        let outBottom = outsets.bottom * scale

        let canvasWidth = Int(ceil(imgWidth + outLeft + outRight))
        let canvasHeight = Int(ceil(imgHeight + outTop + outBottom))

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: canvasWidth,
                  height: canvasHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return image
        }

        let windowRect = CGRect(x: outLeft, y: outBottom, width: imgWidth, height: imgHeight)
        let radius = max(0, cornerRadiusPoints * scale)
        let roundedPath = CGPath(roundedRect: windowRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // 1. 绘制多层物理拟物阴影
        let layers = shadowLayers(forSize: shadowSize)
        for layer in layers {
            context.saveGState()
            // CoreGraphics 坐标系中，y 向上为正。因此向下投影需要负 offsetY。
            let shadowOffset = CGSize(width: 0, height: -layer.offsetY * scale)
            let shadowColor = NSColor.black.withAlphaComponent(layer.opacity).cgColor
            context.setShadow(offset: shadowOffset, blur: layer.blur * scale, color: shadowColor)
            context.addPath(roundedPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
        }

        // 2. 擦除窗口本体区域内部的阴影，避免半透明材质窗口（如毛玻璃终端、Safari）透底变暗
        context.saveGState()
        context.setBlendMode(.clear)
        context.addPath(roundedPath)
        context.fillPath()
        context.restoreGState()

        // 3. 绘制窗口本体内容
        context.draw(image, in: windowRect)

        return context.makeImage() ?? image
    }

    /// 综合特效入口：裁切圆角并在开启阴影时叠加 macOS 拟物阴影。
    static func applyWindowEffects(
        to image: CGImage,
        shadowEnabled: Bool = true,
        shadowSize: CGFloat = 32,
        cornerRadiusPoints: CGFloat = 10,
        scale: CGFloat = 2
    ) -> CGImage {
        let rounded = roundedCorners(image: image, radiusPoints: cornerRadiusPoints, scale: scale)
        if shadowEnabled && shadowSize > 0 {
            return withShadow(
                image: rounded,
                shadowSize: shadowSize,
                cornerRadiusPoints: cornerRadiusPoints,
                scale: scale
            )
        } else {
            return rounded
        }
    }
}
