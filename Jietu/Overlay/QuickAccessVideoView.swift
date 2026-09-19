import AppKit
import SwiftUI

/// 录屏收工后的浮窗卡片（Quick Access Overlay 的视频版）。
///
/// 与图片卡（`QuickAccessView`）同一套表面与交互：卡片尺寸按封面等比算、悬停模糊露出毛玻璃、
/// 浮出同一套 `GlassControlButton`、拖出去就是那个文件。动作：
/// - 上排：**复制文件 / 在访达中显示 / 关闭**（圆盘图标）；
/// - 下排：**MP4(胶囊) / 裁剪(圆盘) / GIF(胶囊)**——格式导出按钮用胶囊标注格式名，一眼可识别；
/// - 中央圆盘：**播放**（点击 = 用 macOS 自带的「预览」打开）。
///
/// 封面正中挂一枚「▶ 0:12」胶囊：一眼看出这是段视频、多长；悬停时它淡出，
/// **同一个位置**换成「播放」——同一个意思、同一个位置，点下去就是预览。
///
/// @author ixxxxoooo
struct QuickAccessVideoView: View {
    /// 封面帧（录好的 mp4 里取一帧）。
    let thumbnail: NSImage
    /// 封面的自然点尺寸：决定它在卡片里显示多大。
    var thumbnailPointSize: CGSize = .zero
    /// 成片时长（秒）。
    let duration: TimeInterval
    /// 卡片尺寸（由控制器算好，与面板 frame 一致）。
    let cardSize: CGSize
    var onPlay: () -> Void
    var onReveal: () -> Void
    var onCopyFile: () -> Void
    /// 中央「保存」：把成片另存一份到用户挑的地方（原片留在保存目录）。
    var onSave: () -> Void
    /// 「裁剪」：开裁剪窗口，掐头去尾另存一段。
    var onTrim: () -> Void
    /// 「导出 GIF」：转一份动图。
    var onExportGif: () -> Void
    var onClose: () -> Void
    var onHoverChange: (Bool) -> Void
    /// 拖拽导出：直接给磁盘上那个 mp4（不是临时文件）。
    var dragProvider: () -> NSItemProvider

    /// 光标是否落在卡片上；由图标层上报（同一份判断驱动模糊与图标显隐）。
    @State private var isHovering = false

    /// 封面在卡片里该显示多大：与图片卡同一口径（等比、不放大、居中留白）。
    var thumbnailDisplaySize: CGSize {
        let size = thumbnailPointSize.width > 0 && thumbnailPointSize.height > 0
            ? thumbnailPointSize : cardSize
        let fit = min(cardSize.width / size.width, cardSize.height / size.height)
        let scale = min(1, fit)
        return CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }

    var body: some View {
        ZStack {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: thumbnailDisplaySize.width, height: thumbnailDisplaySize.height)
                // 悬停轻微模糊，把底下的毛玻璃透出来（与图片卡同一套手感）。
                .blur(radius: isHovering ? min(16, max(4, thumbnailDisplaySize.width / 8)) : 0)
                .clipped()
                .overlay { durationBadge }
                // 热区撑回整张卡片：小封面居中留白，边上也要能点 / 能拖。
                .frame(width: cardSize.width, height: cardSize.height)
                .contentShape(Rectangle())
                .onTapGesture { onPlay() }
                .onDrag { dragProvider() }

            controls
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .glassPanel(cornerRadius: Theme.Radius.menuPanel)
        .help("点击播放，拖拽到其它 App 或文件夹可导出")
        .animation(.easeOut(duration: Theme.Duration.hover), value: isHovering)
    }

    /// 「▶ 0:12」：视频的抬头。
    ///
    /// 用黑底白字的胶囊而不是玻璃：封面可能是任何画面（亮的、花的），
    /// 这枚胶囊必须一眼看得见——视频缩略图那套老规矩最好用。
    ///
    /// 悬停时淡出：中央那个位子要让给「保存」（与图片卡同构，主操作都在中央）。
    private var durationBadge: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(Self.durationText(duration))
                .font(Theme.Typography.numeric)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: 26)
        .background(Capsule().fill(.black.opacity(0.55)))
        .opacity(isHovering ? 0 : 1)
    }

    /// 时长文本：`m:ss`，超过一小时才带上小时位（`h:mm:ss`）。
    ///
    /// 纯函数，单测直接钉它——录屏动辄十几分钟，`00:12` 那种补零写法在这里反而难读。
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// 上排圆盘 + 下排胶囊/圆盘 + 中央「播放」，与图片卡共用同一套玻璃按钮与同一套摆位。
    private var controls: some View {
        QuickAccessControlLayer(
            actions: QuickAccessAction.videoCard,
            onAction: { action in
                switch action {
                case .play: onPlay()
                case .reveal: onReveal()
                case .copyFile: onCopyFile()
                case .saveVideo: onSave()
                case .trimVideo: onTrim()
                case .exportGif: onExportGif()
                case .close: onClose()
                default: break
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
