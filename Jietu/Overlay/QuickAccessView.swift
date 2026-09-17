import AppKit
import SwiftUI

/// 截图后的浮动预览（Quick Access Overlay）。
///
/// 设计取向是「**截图本身是视觉主体**」：
/// - 卡片尺寸按截图**原始宽高比**等比算出来，只受最大尺寸限制，永不拉伸；
/// - 截图不贴边：卡片外面留一圈外框（与钉图同款 `PreviewCard`，macOS 预览窗口那个样子）；
/// - 默认状态只有截图本身，不显示任何操作按钮；
/// - 悬停时截图轻微模糊，**露出底下的毛玻璃**（而不是压色 / 缩放），操作层浮在截图之上；
///   悬停由图标层（AppKit tracking）判定并上报，卡片模糊 / 图标显隐 / 暂停自动关闭同源；
/// - 表面是浮动面板玻璃（后方色彩模糊）、不描边，与拖拽授权面板同款配方；
///   大圆角用 `.continuous`（squircle）；阴影交给系统窗口阴影（多层弥散、随外观自适应）。
///
/// @author ixxxxoooo
struct QuickAccessView: View {
    let image: NSImage
    /// 截图的**自然点尺寸**（像素 ÷ 屏幕缩放）：决定它在卡片里显示多大。
    var imagePointSize: CGSize = .zero
    /// 卡片尺寸（由控制器按截图尺寸算好，保证与面板 frame 一致）。
    let cardSize: CGSize
    var onCopy: () -> Void
    var onSave: () -> Void
    var onAnnotate: () -> Void
    var onPin: () -> Void
    var onClose: () -> Void
    var onHoverChange: (Bool) -> Void
    /// 拖拽导出用：向外提供 PNG 文件。
    var dragProvider: () -> NSItemProvider

    /// 光标是否落在卡片上；由图标层上报（同一份判断驱动模糊与图标显隐）。
    @State private var isHovering = false

    /// 卡片外框圆角：与钉图同一套（`PreviewCard`）。
    private static let cornerRadius = PreviewCard.cornerRadius

    /// 内容区尺寸 = 卡片减掉外框那一圈（截图住在这里面）。
    var contentAreaSize: CGSize {
        CGSize(
            width: max(1, cardSize.width - PreviewCard.inset * 2),
            height: max(1, cardSize.height - PreviewCard.inset * 2)
        )
    }

    /// 图片在卡片里该显示多大：等比放进**内容区**，且**不放大**
    /// （小图保持原始点尺寸、居中留白）。
    var imageDisplaySize: CGSize {
        let area = contentAreaSize
        let size = imagePointSize.width > 0 && imagePointSize.height > 0 ? imagePointSize : area
        let fit = min(area.width / size.width, area.height / size.height)
        let scale = min(1, fit)
        return CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }

    /// 卡片尺寸：截图等比缩放到最大框的**内容区**里，再包上外框、夹进最小框。
    ///
    /// 只等比缩放 → 不拉伸、不变形；只受上下限约束 → 尺寸不同的截图走同一套交互。
    ///
    /// 最小框是给极端宽高比兜底的：竖长截图（1:4）按比例算出来只有几十点宽，
    /// 四角按钮会互相压住、中央胶囊也放不下；超宽截图则只剩十几点高。
    /// 夹住之后图片按比例居中留白（`.fit`），既不拉伸，按钮也永远有地方站。
    ///
    /// - Parameter imagePointSize: 图片的自然点尺寸（不是像素）。
    static func panelSize(for imagePointSize: CGSize) -> CGSize {
        let maxSize = Theme.Size.quickAccessCardMax
        let minSize = Theme.Size.quickAccessCardMin
        let imageSize = imagePointSize
        guard imageSize.width > 0, imageSize.height > 0 else { return maxSize }
        let layout = PreviewCard.inset * 2
        let maxContent = CGSize(
            width: max(1, maxSize.width - layout),
            height: max(1, maxSize.height - layout)
        )
        // `min(1, ...)`：小图**不放大**（截了 20×10 点的图就按 20×10 显示，
        // 卡片按最小尺寸兜底、图片居中）。以前这里没夹 1，几十像素的小图会被撑到 260 宽。
        let scale = min(1, min(maxContent.width / imageSize.width, maxContent.height / imageSize.height))
        let content = CGSize(
            width: (imageSize.width * scale).rounded(),
            height: (imageSize.height * scale).rounded()
        )
        return CGSize(
            width: min(maxSize.width, max(minSize.width, content.width + layout)),
            height: min(maxSize.height, max(minSize.height, content.height + layout))
        )
    }

    var body: some View {
        ZStack {
            // 截图不贴边：卡片比它大一圈，那一圈就是预览卡片的外框（与钉图同款）。
            Image(nsImage: image)
                .resizable()
                // `.fit`：卡片正好是图片的等比尺寸时=铺满内容区；被最小尺寸夹住时=居中留白（不裁切、不拉伸）。
                .aspectRatio(contentMode: .fit)
                // 不铺满整张卡片：`imageDisplaySize` 已经保证「放得下且不放大」，
                // 小图居中、大图正好填满内容区。
                .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
                // 悬停时轻微模糊，把底下的毛玻璃透出来；不压色、不缩放，
                // 按钮自己带玻璃底，不靠压暗截图来凸显。
                // 模糊半径跟着图片尺寸走：固定 16 会把几十点的小图直接糊没（只剩一块毛玻璃）。
                .blur(radius: isHovering ? min(16, max(4, imageDisplaySize.width / 8)) : 0)
                // 截图自己那圈发丝描边：白图 / 深图都从外框里「浮」出来。
                .clipShape(
                    RoundedRectangle(cornerRadius: PreviewCard.contentRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: PreviewCard.contentRadius, style: .continuous)
                        .strokeBorder(Theme.Colors.cardStroke, lineWidth: Theme.Size.hairline)
                }
                // 热区再撑回**整张卡片**：小图（几十点）在卡片里居中留白，边上也得能点 / 能拖。
                // 手势只能挂在图片这一层：挂到上面的 ZStack 上，SwiftUI 会把点击装到容器上，
                // 连 AppKit 那层图标按钮的点击都一起抢走（自检里量到五个图标全点不动）。
                .frame(width: cardSize.width, height: cardSize.height)
                .contentShape(Rectangle())
                .onTapGesture { onAnnotate() }
                .onDrag { dragProvider() }

            // 操作层：悬停才出现，浮在截图上方，不改变截图本身的观感。
            controls
        }
        .frame(width: cardSize.width, height: cardSize.height)
        // 底色：后方色彩模糊的玻璃（透明 PNG / 悬停模糊时才透出来）。
        // 与授权面板 / 钉图同款：静态 `.regular` 玻璃 + `PreviewCard` 大圆角 + 发丝描边。
        .glassPanel(cornerRadius: Self.cornerRadius)
        .previewCardBorder(cornerRadius: Self.cornerRadius)
        .help("点击打开标注编辑器，拖拽到其它 App 或文件夹可导出")
        // 克制：只做一次短淡入，缩放 / 位移一概不做。
        .animation(.easeOut(duration: Theme.Duration.hover), value: isHovering)
    }

    /// 四角圆形图标 + 中间「保存」胶囊，**与钉图共用同一套玻璃图标按钮**
    /// （同款系统玻璃、悬停微光、按下缩放反馈、首击即生效）。
    ///
    /// 悬停由这一层自己判定（AppKit tracking）并上报：卡片模糊、浮窗暂停自动关闭、
    /// 图标显隐都跟着同一个来源，不会出现「按钮已经浮出来了、卡片还是静的」。
    private var controls: some View {
        QuickAccessControlLayer(
            onAction: { action in
                switch action {
                case .close: onClose()
                case .pin: onPin()
                case .annotate: onAnnotate()
                case .copy: onCopy()
                case .save: onSave()
                }
            },
            onHoverChange: { hovering in
                isHovering = hovering
                onHoverChange(hovering)
            }
        )
        .frame(width: cardSize.width, height: cardSize.height)
    }
}
