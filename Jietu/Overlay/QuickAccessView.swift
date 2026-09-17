import AppKit
import SwiftUI

/// 截图后的浮动预览（Quick Access Overlay）。
///
/// 设计取向是「**截图本身是视觉主体**」：
/// - 卡片尺寸按截图**原始宽高比**等比算出来，只受最大尺寸限制，永不拉伸；
/// - 默认状态只有截图本身，不显示任何操作按钮；
/// - 悬停时截图轻微模糊，**露出底下的毛玻璃**（而不是压色 / 缩放），操作层浮在截图之上；
/// - 表面是浮动面板玻璃（后方色彩模糊）、不描边，与拖拽授权面板同款配方；
///   大圆角用 `.continuous`（squircle）；阴影交给系统窗口阴影（多层弥散、随外观自适应）。
///
/// @author ixxxxoooo
struct QuickAccessView: View {
    let image: NSImage
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

    @State private var isHovering = false

    private static let cornerRadius = Theme.Radius.menuPanel

    /// 卡片尺寸：按截图宽高比等比塞进最大框。
    ///
    /// 只等比缩放 → 不拉伸、不变形；只受上限约束 → 尺寸不同的截图走同一套交互。
    static func panelSize(for imageSize: CGSize) -> CGSize {
        let maxSize = Theme.Size.quickAccessCardMax
        guard imageSize.width > 0, imageSize.height > 0 else { return maxSize }
        let scale = min(maxSize.width / imageSize.width, maxSize.height / imageSize.height)
        return CGSize(
            width: max(1, (imageSize.width * scale).rounded()),
            height: max(1, (imageSize.height * scale).rounded())
        )
    }

    var body: some View {
        ZStack {
            // 截图就是卡片本身：恰好铺满，不留边、不拉伸。
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: cardSize.width, height: cardSize.height)
                // 悬停时轻微模糊，把底下的毛玻璃透出来；不压色、不缩放，
                // 按钮自己带玻璃底，不靠压暗截图来凸显。
                .blur(radius: isHovering ? 16 : 0)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { onAnnotate() }
                .onDrag { dragProvider() }

            // 操作层：悬停才出现，浮在截图上方，不改变截图本身的观感。
            controls
        }
        .frame(width: cardSize.width, height: cardSize.height)
        // 底色：后方色彩模糊的玻璃（透明 PNG / 悬停模糊时才透出来）。
        // 与拖拽授权面板同款：静态 `.regular` 玻璃 + `Radius.menuPanel`，**不描边**。
        .glassPanel(cornerRadius: Self.cornerRadius)
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
