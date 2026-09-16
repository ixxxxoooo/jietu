import AppKit
import SwiftUI

/// 截图后的浮动预览（Quick Access Overlay）。
///
/// 设计取向是「**截图本身是视觉主体**」：
/// - 卡片尺寸按截图**原始宽高比**等比算出来，只受最大尺寸限制，永不拉伸；
/// - 默认状态只有截图本身，不显示任何操作按钮；
/// - 悬停时截图轻微模糊，**露出底下的毛玻璃**（而不是压色 / 缩放），操作层浮在截图之上；
/// - 表面是浮动面板玻璃（后方色彩模糊）+ 极细内描边 + 顶部微光，
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
        .glassPanel(cornerRadius: Self.cornerRadius)
        // 极细内描边 + 顶部微光：任何壁纸上都有一条能认出来的边。
        .overlay(rim)
        .help("点击打开标注编辑器，拖拽到其它 App 或文件夹可导出")
        // 克制：只做一次短淡入，缩放 / 位移一概不做。
        .animation(.easeOut(duration: Theme.Duration.hover), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            onHoverChange(hovering)
        }
    }

    /// 极细内描边：顶部略亮、往下淡出，就是那层「轻量微光」。
    ///
    /// 刻意做得**淡而细**（半个点 + 低透明度），只在需要时给出一条边，
    /// 不喧宾夺主地框住截图。
    private var rim: some View {
        let base = isHovering
            ? Theme.Colors.border.opacity(0.55) : Theme.Colors.cardStroke.opacity(0.45)
        return RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [base, base.opacity(0.3)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: Theme.Size.hairline / 2
            )
    }

    /// 四角圆形图标 + 中间保存按钮；它们自己带玻璃底，不靠压暗截图来凸显。
    private var controls: some View {
        ZStack {
            GlassButton(title: "保存", systemImage: "square.and.arrow.down", action: onSave)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    GlassCircleButton(title: "关闭", systemImage: "xmark", action: onClose)
                    Spacer(minLength: 0)
                    GlassCircleButton(title: "钉图", systemImage: "pin", action: onPin)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    GlassCircleButton(
                        title: "标注", systemImage: "pencil.tip.crop.circle", action: onAnnotate)
                    Spacer(minLength: 0)
                    GlassCircleButton(title: "复制", systemImage: "doc.on.doc", action: onCopy)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
    }
}
