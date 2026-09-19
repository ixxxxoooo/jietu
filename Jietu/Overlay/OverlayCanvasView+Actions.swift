import AppKit

/// 遮罩画布 — 提交/取消/确认等终结操作。
///
/// @author ixxxxoooo
extension OverlayCanvasView {

    func commit() {
        if phase == .annotating {
            confirmInline()
            return
        }
        if selection == nil, let windowRect = hoveredWindowLocalRect {
            selection = windowRect
            updateAllLayers()
            interaction = .settled
            Self.rememberedSelection[snapshot.displayID] = windowRect
        }
        guard let selection, selection.width >= 1, selection.height >= 1 else { return }
        if inlineMode {
            enterAnnotating()
            return
        }
        Self.rememberedSelection[snapshot.displayID] = selection
        onCommit?(selection)
    }

    func restoreRememberedSelection() {
        guard let remembered = Self.rememberedSelection[snapshot.displayID] else { return }
        let rect = remembered.intersection(canvasBounds)
        guard !rect.isEmpty else { return }
        selection = rect
        interaction = .settled
        updateAllLayers()
        updateHoveredWindow(at: cursorPoint ?? .zero)
        updateWindowHighlight()
        if isRegionPickMode {
            notifySelectionChanged()
            firePauseSignal()
        }
    }

    func nudge(keyCode: UInt16, large: Bool) {
        guard let selection else { return }
        let step: CGFloat = large ? 10 : 1
        var delta = CGSize.zero
        switch keyCode {
        case 123: delta.width = -step
        case 124: delta.width = step
        case 125: delta.height = -step
        case 126: delta.height = step
        default: return
        }
        self.selection = SelectionGeometry.moved(
            selection,
            by: delta,
            clampTo: canvasBounds
        )
        updateAllLayers()
        if isRegionPickMode {
            notifySelectionChanged()
            schedulePauseSignal()
        }
    }
}

/// 选区尺寸胶囊标签图层：使用 CoreText 绘制单行尺寸文本，上下左右留白精确对称，避免垂直偏心错位。
nonisolated final class PillLabelLayer: CALayer {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    var text: String = ""
    var textWidth: CGFloat = 0

    override init() {
        super.init()
        backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        cornerRadius = 4
        masksToBounds = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? PillLabelLayer {
            self.text = other.text
            self.textWidth = other.textWidth
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func action(forKey event: String) -> CAAction? {
        nil
    }

    func set(text: String) {
        guard self.text != text else { return }
        self.text = text
        let attr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.cgColor,
        ]
        let attrString = NSAttributedString(string: text, attributes: attr)
        let line = CTLineCreateWithAttributedString(attrString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        setNeedsDisplay()
    }

    func calculateSize() -> CGSize {
        let paddingH: CGFloat = 7
        let paddingV: CGFloat = 5
        let w = ceil(textWidth + paddingH * 2)
        let h = ceil(font.capHeight + paddingV * 2)
        return CGSize(width: w, height: h)
    }

    override func draw(in ctx: CGContext) {
        guard !text.isEmpty else { return }
        let attr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.cgColor,
        ]
        let attrString = NSAttributedString(string: text, attributes: attr)
        let line = CTLineCreateWithAttributedString(attrString)
        let y = (bounds.height - font.capHeight) / 2
        let x = (bounds.width - textWidth) / 2
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }
}
