import AppKit
import SwiftUI

/// Jietu 的设计令牌，风格对齐 `~/tinycast` 的 `Tinycast/DesignSystem/Theme.swift`。
///
/// 承重规则（详见 `.specstory/history/docs/20260916_UI设计规范.md`）：
/// 1. 表面 = 磨砂 + 墨色 scrim；
/// 2. 只有一条 alpha ramp，不用灰（深色白墨 / 浅色黑墨）；
/// 3. 浮动条不是 chrome；
/// 4. 边角是溶解不是裁切；
/// 5. 玻璃只给浮动控件。
///
/// @author ixxxxoooo
enum Theme {
    // MARK: - Colors

    /// 一条 alpha ramp：深色底上是白墨、浅色底上是黑墨，alpha 停在固定档位。
    enum Colors {
        /// 按窗口的 `effectiveAppearance` 实时解析，token 自己会重绘。
        static func adaptive(dark: NSColor, light: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
        }

        /// ramp：深色用白墨 `dark`、浅色用黑墨 `light`。
        static func ramp(dark: Double, light: Double) -> Color {
            adaptive(dark: .srgbInk(1, alpha: dark), light: .srgbInk(0, alpha: light))
        }

        /// ramp 的反向：深色压黑、浅色压白，用于面板 / 浮窗 / 工具栏压底。
        static let panelScrim = adaptive(
            dark: .srgbInk(0, alpha: 0.40), light: .srgbInk(1, alpha: 0.55))

        /// 选中行填充，所有列表共用。
        static let selection = ramp(dark: 0.10, light: 0.09)
        /// 鼠标悬停：比选中更淡的一层。
        static let rowHover = ramp(dark: 0.05, light: 0.045)
        /// 下拉菜单行悬停。
        static let menuHover = ramp(dark: 0.10, light: 0.09)
        /// 列表与预览之间的 1px 细线。
        static let separator = ramp(dark: 0.10, light: 0.12)
        /// 小控件表面：填充 keycap、分段控件选中底、字形块。
        static let controlSurface = ramp(dark: 0.10, light: 0.08)
        /// 控件描边：描边 keycap、卡片边框。
        static let border = ramp(dark: 0.20, light: 0.18)
        /// alpha 1，调用方用 `.opacity` 自己压暗即可落到目标值。
        static let textPrimary = ramp(dark: 1.0, light: 1.0)
        static let textSecondary = ramp(dark: 0.60, light: 0.60)
        /// 工具栏 / 二级菜单里的图标：比 `textSecondary` 更实一些，
        /// 压在磨砂面板上才看得清（选中态还是 `textPrimary` + 高亮底，层次不受影响）。
        static let toolbarIcon = ramp(dark: 0.85, light: 0.85)
        static let textTertiary = ramp(dark: 0.40, light: 0.42)
        /// 图标解码前的空块。
        static let iconPlaceholder = ramp(dark: 0.06, light: 0.06)
        /// 引导页顶部那层很淡的洗色。
        static let sheen = ramp(dark: 0.04, light: 0.04)
        /// 设置卡片底，边框兼作行分隔。
        static let cardFill = ramp(dark: 0.05, light: 0.04)
        static let cardStroke = ramp(dark: 0.10, light: 0.10)
        /// 玻璃色调：明暗都是白，浅色玻璃需要更多才读得出来。
        static let glassFrost = adaptive(
            dark: .srgbInk(1, alpha: 0.05), light: .srgbInk(1, alpha: 0.25))

        // MARK: Jietu 功能色（不属于 ramp）

        /// 统一强调色：取自 `Assets.xcassets/AccentColor`（= 品牌蓝 #0D44E8）。
        ///
        /// 图标、开关打开态、分段 / 单选 / 焦点态都从这一处取色——参考项目里图标配色
        /// 也只从单一 token 取（`menuSymbol` / `accentColor`），**不逐分区换色**。
        static let accent = Color.accentColor

        /// 图标统一颜色（侧边栏、设置行、工具条都取它）。
        static let icon = accent

        /// Jietu 品牌蓝，与 `AccentColor` 资产同源。
        static let brand = accent
        /// 截图选框 / 控制点绿（功能色，不可被 ramp 替换）。
        static let selectionGreen = Color(red: 0.14, green: 0.87, blue: 0.45)
        /// 破坏性操作：取消、删除。
        static let destructive = Color.red
        /// 成功：完成、已授权。
        static let success = Color.green
        /// 警告：未授权、热键冲突。
        static let warning = Color.orange
        /// 进行中：加载、滚动拼接。
        static let progress = Color.blue
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 20
        static let xxxl: CGFloat = 28
        /// 区块标题与其内容之间的间距。
        static let sectionHeaderBottom: CGFloat = 4
        /// 区块之间的间距，读起来像上一段的收尾。
        static let sectionSpacing: CGFloat = 12
    }

    // MARK: - Radius（一律 .continuous）

    enum Radius {
        /// 大面板裁切。
        static let panel: CGFloat = 26
        /// 对话框 / 浮窗表面。
        static let dialog: CGFloat = 20
        /// 浮动菜单 / 标注工具栏 / QAO 卡片 / 控制条。
        static let menuPanel: CGFloat = 16
        /// 设置卡片 / 普通卡片。
        static let card: CGFloat = 10
        /// 列表行悬停底。
        static let row: CGFloat = 10
        /// 顶部下拉按钮、圆角版按钮悬停胶囊。
        static let barControl: CGFloat = 8
        /// 小控件（快捷键录制器、侧栏方块）。
        static let menu: CGFloat = 6
        /// keycap 芯片。
        static let keyCap: CGFloat = 6
        /// 录制器里的按键芯片，比 keycap 芯片再小一档。
        static let recorderKeyCap: CGFloat = 4
        /// 缩略图。
        static let thumbnail: CGFloat = 6
        /// 小到用 thumbnail 会被圆成球的小方块。
        static let glyph: CGFloat = 2
    }

    // MARK: - Size

    enum Size {
        /// 设置窗口（Tinycast 900×700，Jietu 面板更少故收窄）。
        static let settingsWindow = CGSize(width: 820, height: 600)
        /// 设置侧边栏固定列宽。
        static let settingsSidebar: CGFloat = 215
        /// 详情列最窄，再窄分组行的控件就开始打架。
        static let settingsDetailMinimum: CGFloat = 420
        /// 侧栏搜索框 / 分段控件行高，与分组行控件等高。
        static let settingsSearchField: CGFloat = 28
        /// 设置行首图标槽。
        static let settingsRowIcon: CGFloat = 20
        /// 底部操作组的位置。
        static let settingsContentInset: CGFloat = 22

        /// 工具条按钮的悬停胶囊高。
        static let barButtonHeight: CGFloat = 28
        /// 一条细线。
        static let hairline: CGFloat = 1
        /// 列表行图标槽。
        static let rowIcon: CGFloat = 24

        /// keycap 三档：compact 提示、standard 常规、hero 内容。
        static let compactKeyCap: CGFloat = 15
        static let keyCap: CGFloat = 18
        static let heroKeyCap: CGFloat = 22

        /// 快捷键录制器：宽高固定，绑定的组合键变化时控件不会变形。
        static let shortcutRecorder: CGFloat = 120
        static let shortcutRecorderHeight: CGFloat = 24
        /// 录制器里的按键芯片，比 keycap 芯片更小一档。
        static let recorderKeyCap: CGFloat = 16

        /// 对话框宽度与前置字形。
        static let dialogWidth: CGFloat = 420
        static let dialogIcon: CGFloat = 32

        /// 标注工具栏的图标按钮。
        static let toolbarButtonWidth: CGFloat = 30
        static let toolbarButtonHeight: CGFloat = 26
        /// 工具栏内竖分隔线高。
        static let toolbarSeparatorHeight: CGFloat = 20
        /// 工具栏内边距。
        static let toolbarPadding: CGFloat = 10
        /// 工具栏内元素间距。
        static let toolbarItemSpacing: CGFloat = 4
        /// 工具栏图标默认字号。
        static let toolbarIconSize: CGFloat = 15

        /// 行悬停胶囊的宽度上限。
        static let popoverMenuWidth: CGFloat = 276

        /// QAO 卡片的**最大**尺寸：截图按原始宽高比等比缩进来，永不拉伸。
        /// 阴影由系统窗口阴影负责，不留白。
        static let quickAccessCardMax = CGSize(width: 260, height: 180)
        /// QAO 卡片的**最小**尺寸：极端宽高比（竖长截图 / 超宽截图）按原始比例算出来只有几十点宽
        /// （甚至十几点高），按钮就会互相压住、胶囊也放不下。兜一个下限，图片居中留白，不拉伸。
        static let quickAccessCardMin = CGSize(width: 96, height: 112)
        /// QAO 距屏幕边缘。
        static let quickAccessInset: CGFloat = 20

        /// 滚动长图控制条（高度按「一行状态 + 最多两行提示 + 一行按钮」算出来，不裁剪）。
        static let scrollingPanel = CGSize(width: 330, height: 136)
        /// 滚动长图的「手动 / 自动」模式条：贴在选框下方的一条窄条（先选谁来滚）。
        static let scrollingModeBar = CGSize(width: 252, height: 46)
        /// 模式条上的关闭圆钮。
        static let scrollingModeBarClose: CGFloat = 22
        /// 历史面板。
        static let historyPanel = CGSize(width: 340, height: 560)
        /// 权限引导窗口。
        static let onboarding = CGSize(width: 520, height: 380)
        /// 历史面板 / 引导页的通用内边距。
        static let panelPadding: CGFloat = 16
    }

    // MARK: - Typography

    enum Typography {
        /// 一个尺寸两处用：SwiftUI 与 NSFont（用于测量）。
        static let searchFieldSize: CGFloat = 20
        static let searchField = Font.system(size: searchFieldSize, weight: .regular)

        static let headerIcon = Font.system(size: 18, weight: .medium)

        /// 面板 / 对话框自己的标题，命名的是这个表面。
        static let title = Font.headline
        static let rowTitle = Font.body
        static let rowSubtitle = Font.caption
        static let sectionHeader = Font.subheadline.weight(.medium)
        /// 浮动条上的控件文字。
        static let bar = Font.callout.weight(.medium)
        static let chip = Font.callout
        static let keyCap = Font.caption
        static let compactKeyCap = Font.caption2
        static let heroKeyCap = Font.body
        /// 下拉控件尾部的箭头，刻意比标签小。
        static let disclosure = Font.caption.weight(.semibold)
        static let code = Font.system(.callout, design: .monospaced)
        /// 数值读数（进度、百分比）。
        static let numeric = Font.callout.monospacedDigit()
    }

    // MARK: - Duration

    enum Duration {
        /// 表面进场：淡入同时 0.94→1。
        static let enter: TimeInterval = 0.18
        /// 表面退场，比进场短才有"利落"感。
        static let exit: TimeInterval = 0.12
        /// 控件响应悬停。
        static let hover: TimeInterval = 0.12
        static let tooltip: TimeInterval = 0.15
        /// 悬停提示气泡初始出现延迟（避免鼠标掠过时立刻弹出）。
        static let tooltipDelay: TimeInterval = 0.45
        /// 连续浏览相邻控件时复用提示的短暂延迟。
        static let tooltipReshowDelay: TimeInterval = 0.05
        /// 原地工具栏淡入。
        static let toolbarFadeIn: TimeInterval = 0.15
        /// QAO 侧滑。
        static let quickAccessSlideIn: TimeInterval = 0.25
    }

    // MARK: - 遮罩画布功能参数（不属于组件风格）

    /// 选区外压暗程度。
    static let overlayDimAlpha: CGFloat = 0.45
    /// 截图选框虚线宽（粗体线条）。
    static let selectionBorderWidth: CGFloat = 2.5
    /// 选框控制点直径。
    static let selectionHandleSize: CGFloat = 10
    /// 判定「抓到 handle」的半径，比 handle 本身大，好抓。
    static let selectionHandleHitTolerance: CGFloat = 12
    /// 超过这个位移才算框选，否则算单击。
    static let dragActivationDistance: CGFloat = 3
    /// 小于这个尺寸的框选视为误触。与 `SelectionGeometry.minimumSide` 同源。
    static let minimumSelectionSize: CGFloat = SelectionGeometry.minimumSide

    // MARK: - 兼容别名（遮罩 / 面板控制器仍在读，后续可逐步改用上面的 token）

    static let brand = Colors.brand
    static let selectionGreen = Colors.selectionGreen
    static let hudForeground = Colors.ramp(dark: 0.60, light: 0.60)
    static let hudForegroundActive = Colors.textPrimary
    static let hudSelectionFill = Colors.ramp(dark: 0.10, light: 0.09)
    static let hudCornerRadius = Radius.menuPanel
    static let buttonCornerRadius = Radius.barControl
    static let toolbarPadding = Size.toolbarPadding
    static let toolbarItemSpacing = Size.toolbarItemSpacing
    static let toolbarIconSize = Size.toolbarIconSize
    static let quickAccessWidth = Size.quickAccessCardMax.width
    static let quickAccessCornerRadius = Radius.menuPanel
    static let quickAccessInset = Size.quickAccessInset
}

// MARK: - 玻璃

extension View {
    /// 浮在表面上的**玻璃控件**（胶囊 / 圆 / 可交互卡片）。
    ///
    /// `interactive` 让它在悬停 / 按下时有系统反馈，`glassFrost` 把它提亮一档。
    /// **只给控件用**；面板表面用下面的 `glassPanel`。
    func frosted(in shape: some Shape) -> some View {
        glassEffect(.regular.interactive().tint(Theme.Colors.glassFrost), in: shape)
            .tint(.clear)
    }

    /// 浮动**面板表面**的玻璃：静态 `.regular`，不加 `interactive`、不加 tint、不描边。
    ///
    /// 对齐参考项目里浮窗的做法（`PopoverMenu` / `NoteSwitcherView` /
    /// `ExtensionActionsPanel` 都是 `.glassEffect(.regular, in: RoundedRectangle(
    /// cornerRadius: Radius.menuPanel, style: .continuous))`）。
    /// 主表面永远不用玻璃——那是 `FloatingSurface`（磨砂 + scrim）的活。
    func glassPanel(cornerRadius: CGFloat = Theme.Radius.menuPanel) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return glassEffect(.regular, in: shape).clipShape(shape)
    }
}

// MARK: - NSColor 墨色与外观

extension NSColor {
    /// sRGB 墨色：`white` 为 1 是白，为 0 是黑。
    static func srgbInk(_ white: CGFloat, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
    }
}

extension NSAppearance {
    /// 深色外观判定，取 aqua / darkAqua 的最佳匹配。
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
