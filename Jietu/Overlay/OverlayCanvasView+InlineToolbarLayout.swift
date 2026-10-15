import AppKit

/// 遮罩画布 — 原地编辑工具栏的版面计算（横排 / 竖排停靠与选项条定位）。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    func rebuildOptionsToolbar() {
        optionsToolbarHost?.isHidden = !(toolbarModel?.isSubToolbarVisible ?? false)
        layoutToolbars()
    }

    /// 摆工具栏，优先级 **下 → 上 → 右 → 左**：
    /// 先横排贴选区下面（最顺手）；下面放不下就翻到选区上方**横排**；
    /// 上下都没位置才竖排停到右侧，右边也不行再退到左侧；四处都塞不下就夹进画布（别把工具栏弄丢）。
    func layoutToolbars() {
        guard let selection, let main = mainToolbarHost else { return }
        let inset: CGFloat = 8
        let gap: CGFloat = 10

        // 1. 下面。
        let horizontalSize = measureMainToolbar(vertical: false)
        if selection.minY - gap - horizontalSize.height >= bounds.minY + inset {
            placeHorizontal(main, size: horizontalSize, below: selection, inset: inset, gap: gap)
            layoutOptions(beside: main.frame, side: nil, inset: inset, gap: gap)
            return
        }

        // 2. 上面。（以前这里是最后兜底，导致「下面没位置」就直接竖排了——上面明明空着。）
        if selection.maxY + gap + horizontalSize.height <= bounds.maxY - inset {
            placeHorizontal(main, size: horizontalSize, below: selection, inset: inset, gap: gap, above: true)
            layoutOptions(beside: main.frame, side: nil, inset: inset, gap: gap, above: true)
            return
        }

        // 3. 右 → 左（竖排）。
        let verticalSize = measureMainToolbar(vertical: true)
        if let side = verticalDockSide(for: selection, mainSize: verticalSize, inset: inset, gap: gap) {
            placeVertical(main, size: verticalSize, on: side, selection: selection, inset: inset, gap: gap)
            layoutOptions(beside: main.frame, side: side, inset: inset, gap: gap)
            return
        }

        // 4. 四处都没位置 → 横排贴到选区上方，靠 `placeHorizontal` 的夹取收进画布。
        let size = measureMainToolbar(vertical: false)
        placeHorizontal(main, size: size, below: selection, inset: inset, gap: gap, above: true)
        layoutOptions(beside: main.frame, side: nil, inset: inset, gap: gap, above: true)
    }

    /// 量一次主工具栏在某个方向上的尺寸（`isVerticalLayout` 变了要让它先重新排一遍）。
    func measureMainToolbar(vertical: Bool) -> CGSize {
        guard let main = mainToolbarHost, let model = toolbarModel else { return .zero }
        if model.isVerticalLayout != vertical {
            model.isVerticalLayout = vertical
            main.layoutSubtreeIfNeeded()
        }
        return main.fittingSize
    }

    /// 横排：水平居中于选区，放在选区下面（`above = true` 时放上面）。
    func placeHorizontal(
        _ main: NSView,
        size: CGSize,
        below selection: CGRect,
        inset: CGFloat,
        gap: CGFloat,
        above: Bool = false
    ) {
        var origin = CGPoint(
            x: selection.midX - size.width / 2,
            y: above ? selection.maxY + gap : selection.minY - size.height - gap
        )
        origin.x = min(
            max(origin.x, bounds.minX + inset),
            max(bounds.minX + inset, bounds.maxX - size.width - inset)
        )
        origin.y = min(max(origin.y, bounds.minY + inset), bounds.maxY - size.height - inset)
        main.frame = CGRect(origin: origin, size: size)
    }

    /// 竖排能停在哪一侧？优先右侧，其次左侧；都放不下返回 nil。
    func verticalDockSide(
        for selection: CGRect,
        mainSize: CGSize,
        inset: CGFloat,
        gap: CGFloat
    ) -> VerticalDockSide? {
        guard mainSize.width > 0, mainSize.height > 0 else { return nil }
        // 竖排要够高（工具栏很长），也要在选区旁边放得下。
        guard mainSize.height <= bounds.height - inset * 2 else { return nil }
        let optionsSize = visibleOptionsSize()
        let columnWidth = mainSize.width + (optionsSize.width > 0 ? gap + optionsSize.width : 0)
        let roomLeft = selection.minX - bounds.minX
        let roomRight = bounds.maxX - selection.maxX
        if roomRight >= columnWidth + gap + inset { return .right }
        if roomLeft >= columnWidth + gap + inset { return .left }
        return nil
    }

    /// 竖排：贴边停靠，整体在竖直方向居中于选区（并夹进画布）。
    func placeVertical(
        _ main: NSView,
        size: CGSize,
        on side: VerticalDockSide,
        selection: CGRect,
        inset: CGFloat,
        gap: CGFloat
    ) {
        // **贴着选区**摆（不是贴屏幕边）：选区右边放不下才轮到左边，两边都放不下则走兜底。
        let x = side == .right ? selection.maxX + gap : selection.minX - gap - size.width
        var y = selection.midY - size.height / 2
        y = min(max(y, bounds.minY + inset), max(bounds.minY + inset, bounds.maxY - size.height - inset))
        main.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    enum VerticalDockSide {
        case left
        case right
    }

    /// 二级菜单当前的尺寸（不显示时为零）。
    func visibleOptionsSize() -> CGSize {
        guard let options = optionsToolbarHost, let model = toolbarModel, model.isSubToolbarVisible
        else { return .zero }
        options.layoutSubtreeIfNeeded()
        return options.fittingSize
    }

    /// 摆二级菜单：贴着主工具栏。
    ///
    /// - 横排（`side == nil`）：居中挂在主栏的**外侧**——主栏在选区下面（`above == false`）就挂在
    ///   主栏更下面，主栏在选区上面（`above == true`）就挂在主栏更上面，总之别往选区里挤；
    ///   那一侧放不下才翻回主栏与选区之间。
    /// - 竖排：也跟着竖排，挂在主栏**外侧**（离选区远的那一边），与主栏上下居中。
    func layoutOptions(
        beside mainFrame: CGRect,
        side: VerticalDockSide?,
        inset: CGFloat,
        gap: CGFloat,
        above: Bool = false
    ) {
        guard let options = optionsToolbarHost, let model = toolbarModel, model.isSubToolbarVisible else {
            optionsToolbarHost?.isHidden = true
            return
        }
        options.isHidden = false
        let size = visibleOptionsSize()
        guard size.width > 0, size.height > 0 else { return }

        if let side {
            // 主栏贴着选区，二级菜单挂在主栏**外侧**（离选区远的那一边），别挤在选区和主栏中间；
            // 竖直方向与主栏**上下居中**（主栏本身相对选区居中，这样两条栏看着是一体的）。
            var x = side == .right ? mainFrame.maxX + gap : mainFrame.minX - gap - size.width
            x = min(max(x, bounds.minX + inset), max(bounds.minX + inset, bounds.maxX - size.width - inset))
            let y = min(
                max(mainFrame.midY - size.height / 2, bounds.minY + inset),
                max(bounds.minY + inset, bounds.maxY - size.height - inset)
            )
            options.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            return
        }

        let x = min(
            max(mainFrame.midX - size.width / 2, bounds.minX + inset),
            max(bounds.minX + inset, bounds.maxX - size.width - inset)
        )
        let outer = above ? mainFrame.maxY + inset : mainFrame.minY - inset - size.height
        let inner = above ? mainFrame.minY - inset - size.height : mainFrame.maxY + inset
        let outerFits = above
            ? outer + size.height <= bounds.maxY - inset
            : outer >= bounds.minY + inset
        var y = outerFits ? outer : inner
        y = min(max(y, bounds.minY + inset), max(bounds.minY + inset, bounds.maxY - size.height - inset))
        options.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
