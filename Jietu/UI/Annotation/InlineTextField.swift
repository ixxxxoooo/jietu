import AppKit
import SwiftUI

/// 专属文字编辑 Cell：支持动态调整水平/垂直内边距（如标注特效气泡所需的 padding）。
///
/// @author ixxxxoooo
final class InlineTextFieldCell: NSTextFieldCell {
    var paddingH: CGFloat = 2
    var paddingV: CGFloat = 0

    private func contentRect(for rect: NSRect) -> NSRect {
        guard rect.width > paddingH * 2 && rect.height > paddingV * 2 else { return rect }
        return NSRect(
            x: rect.origin.x + paddingH,
            y: rect.origin.y + paddingV,
            width: rect.width - paddingH * 2,
            height: rect.height - paddingV * 2
        )
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let superRect = super.drawingRect(forBounds: rect)
        return contentRect(for: superRect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(withFrame: contentRect(for: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: contentRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

/// 就地文本输入框：
///
/// 特殊交互保障：
/// 1. Esc 退出/取消：正在输入文字时按 Esc 触发取消；
///    若输入法正在组合拼音（`hasMarkedText()`），优先让输入法处理（清除本次拼音），拼音清除后再按 Esc 退出。
/// 2. 拼音自适应宽度：中文拼音在未上屏（markedText）阶段不会写入 `stringValue`，
///    但已存在于 `NSTextView.string` 及 `textStorage` 中。通过监听 `didProcessEditingNotification`
///    和 `didChangeNotification`，在每次打字时通知外部根据实时文字（含拼音）宽度调整文本框 frame。
/// 3. 所见即所得（WYSIWYG）：
///    - 「标注」（callout）：实时呈现纯色圆角气泡底板，文字及光标自动切换为高对比反色（白/黑）；
///    - 「描边」（stroke）：实时呈现高对比描边光晕；
///    - 普通文本：同色半透明极细虚框标出输入边界，无干扰性占位符水印。
///
/// @author ixxxxoooo
final class InlineTextField: NSTextField, NSTextFieldDelegate {
    var onCancelScreenshot: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?
    var onTextWidthChange: (() -> Void)?
    var onTextChanged: ((String) -> Void)?

    private var storageObserver: Any?
    private var textChangeObserver: Any?

    override class var cellClass: AnyClass? {
        get { InlineTextFieldCell.self }
        set { super.cellClass = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.delegate = self
        setupCommon()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.delegate = self
        setupCommon()
    }

    private func setupCommon() {
        isEditable = true
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        alignment = .left
        wantsLayer = true
        target = self
        action = #selector(handleAction)
    }

    @objc private func handleAction() {
        if let editor = currentEditor() as? NSTextView, editor.hasMarkedText() {
            return
        }
        onCommit?()
    }

    func controlTextDidChange(_ obj: Notification) {
        onTextWidthChange?()
        onTextChanged?(currentText())
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        attachEditorObservers()
        return result
    }

    override func selectText(_ sender: Any?) {
        super.selectText(sender)
        attachEditorObservers()
    }

    func attachEditorObservers() {
        guard let editor = currentEditor() as? NSTextView else { return }
        if storageObserver == nil, let storage = editor.textStorage {
            storageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: storage,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.onTextWidthChange?()
                self.onTextChanged?(self.currentText())
            }
        }
        if textChangeObserver == nil {
            textChangeObserver = NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification,
                object: editor,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.onTextWidthChange?()
                self.onTextChanged?(self.currentText())
            }
        }
    }

    func detachEditorObservers() {
        if let obs = storageObserver {
            NotificationCenter.default.removeObserver(obs)
            storageObserver = nil
        }
        if let obs = textChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            textChangeObserver = nil
        }
    }

    deinit {
        detachEditorObservers()
    }

    // MARK: - Key Handling

    override func cancelOperation(_ sender: Any?) {
        if let editor = currentEditor() as? NSTextView, editor.hasMarkedText() {
            super.cancelOperation(sender)
            return
        }
        fireCancel()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { // kVK_Escape
            if let editor = currentEditor() as? NSTextView, editor.hasMarkedText() {
                return super.performKeyEquivalent(with: event)
            }
            fireCancel()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) ||
            commandSelector == #selector(NSResponder.complete(_:))
        {
            if !textView.hasMarkedText() {
                fireCancel()
                return true
            }
        } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if !textView.hasMarkedText() {
                onCommit?()
                return true
            }
        }
        return false
    }

    private func fireCancel() {
        if let onCancelScreenshot {
            onCancelScreenshot()
        } else {
            onCancel?()
        }
    }

    // MARK: - Content & Styling

    /// 获取当前输入框中的完整文本（包括正在输入的拼音 markedText）。
    func currentText() -> String {
        if let editor = currentEditor() as? NSTextView {
            let str = editor.string
            if !str.isEmpty {
                return str
            }
        }
        return stringValue
    }

    /// 应用标注样式（字号、色板、描边、标注底板气泡）。
    func applyStyle(
        fontSize: CGFloat,
        color: RGBAColor,
        hasStroke: Bool,
        hasCallout: Bool
    ) {
        let pointSize = max(10, fontSize)
        let font = NSFont.systemFont(ofSize: pointSize)
        self.font = font
        let nsColor = NSColor(cgColor: color.cgColor) ?? .labelColor
        let lum = 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
        let contrastColor: NSColor = lum > 0.65 ? .black : .white

        guard let inlineCell = cell as? InlineTextFieldCell else { return }

        if hasCallout {
            inlineCell.paddingH = max(6, pointSize * 0.35)
            inlineCell.paddingV = max(3, pointSize * 0.2)
            self.textColor = contrastColor
            wantsLayer = true
            layer?.backgroundColor = color.cgColor
            let lm = NSLayoutManager()
            let lineHeight = ceil(lm.defaultLineHeight(for: font))
            let height = lineHeight + inlineCell.paddingV * 2
            layer?.cornerRadius = min(8, height / 3)
            layer?.borderWidth = 0
            layer?.shadowOpacity = 0
        } else {
            inlineCell.paddingH = 2
            inlineCell.paddingV = 0
            self.textColor = nsColor
            wantsLayer = true
            layer?.backgroundColor = nil
            layer?.cornerRadius = 2
            layer?.borderWidth = 1
            layer?.borderColor = nsColor.withAlphaComponent(0.45).cgColor
            if hasStroke {
                let strokeColor = lum > 0.65 ? NSColor.black.cgColor : NSColor.white.cgColor
                layer?.shadowColor = strokeColor
                layer?.shadowRadius = max(1, pointSize * 0.08)
                layer?.shadowOpacity = 0.95
                layer?.shadowOffset = .zero
            } else {
                layer?.shadowOpacity = 0
            }
        }

        if let editor = currentEditor() as? NSTextView {
            editor.textColor = self.textColor
            editor.font = font
            editor.insertionPointColor = self.textColor ?? .textColor
        }
    }

    /// 根据内容自适应排版尺寸。
    func contentSize() -> CGSize {
        guard let font = font else { return CGSize(width: 24, height: 24) }
        let text = currentText()
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let lm = NSLayoutManager()
        let lineHeight = ceil(lm.defaultLineHeight(for: font))
        let padH = (cell as? InlineTextFieldCell)?.paddingH ?? 2
        let padV = (cell as? InlineTextFieldCell)?.paddingV ?? 0
        let width = max(24, ceil(textWidth) + padH * 2 + 8)
        let height = lineHeight + padV * 2
        return CGSize(width: width, height: height)
    }

    /// 根据原点调整 frame，支持 Flipped（SwiftUI 坐标）与非 Flipped（AppKit 坐标）。
    func fitToOrigin(_ origin: CGPoint, isFlipped: Bool) {
        let size = contentSize()
        let padH = (cell as? InlineTextFieldCell)?.paddingH ?? 2
        let padV = (cell as? InlineTextFieldCell)?.paddingV ?? 0

        let x = origin.x - padH
        let y: CGFloat
        if isFlipped {
            y = origin.y - padV
        } else {
            let lm = NSLayoutManager()
            let lineHeight = ceil(lm.defaultLineHeight(for: font ?? NSFont.systemFont(ofSize: 14)))
            y = origin.y - lineHeight - padV
        }

        self.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// 容纳 `InlineTextField` 的容器视图，提供 SwiftUI 与 AppKit 之间的事件桥接与自适应定位。
final class InlineTextFieldContainerView: NSView {
    override var isFlipped: Bool { true }

    let textField = InlineTextField(frame: .zero)
    var origin: CGPoint = .zero
    var onTextChange: ((String) -> Void)?
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    var isEditingMarkedText: Bool {
        if let editor = textField.currentEditor() as? NSTextView {
            return editor.hasMarkedText()
        }
        return false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = false
        addSubview(textField)

        textField.onCancel = { [weak self] in
            self?.onCancel?()
        }
        textField.onCommit = { [weak self] in
            guard let self else { return }
            self.onCommit?(self.textField.currentText())
        }
        textField.onTextWidthChange = { [weak self] in
            guard let self else { return }
            self.fitField()
        }
        textField.onTextChanged = { [weak self] text in
            guard let self else { return }
            self.fitField()
            self.onTextChange?(text)
        }
    }

    func applyStyle(
        fontSize: CGFloat,
        color: RGBAColor,
        hasStroke: Bool,
        hasCallout: Bool
    ) {
        textField.applyStyle(
            fontSize: fontSize,
            color: color,
            hasStroke: hasStroke,
            hasCallout: hasCallout
        )
        fitField()
    }

    func fitField() {
        textField.fitToOrigin(origin, isFlipped: true)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if textField.frame.contains(point) {
            return super.hitTest(point)
        }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, let win = self.window else { return }
                win.makeFirstResponder(self.textField)
                self.textField.selectText(nil)
                self.textField.attachEditorObservers()
                self.fitField()
            }
        }
    }
}

/// 在 SwiftUI 画布中宿主 `InlineTextField`，保证与原地编辑文本框体验和样式完全一致。
///
/// @author ixxxxoooo
struct InlineTextFieldHost: NSViewRepresentable {
    @Binding var text: String
    var origin: CGPoint
    var fontSize: CGFloat
    var color: RGBAColor
    var hasStroke: Bool
    var hasCallout: Bool
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> InlineTextFieldContainerView {
        let container = InlineTextFieldContainerView()
        container.origin = origin
        container.textField.stringValue = text
        container.onTextChange = { [weak coordinator = context.coordinator] newText in
            coordinator?.parent.text = newText
        }
        container.onCommit = { [weak coordinator = context.coordinator] committedText in
            coordinator?.parent.onCommit(committedText)
        }
        container.onCancel = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onCancel()
        }
        container.applyStyle(
            fontSize: fontSize,
            color: color,
            hasStroke: hasStroke,
            hasCallout: hasCallout
        )
        return container
    }

    func updateNSView(_ nsView: InlineTextFieldContainerView, context: Context) {
        context.coordinator.parent = self
        nsView.origin = origin
        nsView.applyStyle(
            fontSize: fontSize,
            color: color,
            hasStroke: hasStroke,
            hasCallout: hasCallout
        )
        if nsView.textField.currentText() != text && !nsView.isEditingMarkedText {
            nsView.textField.stringValue = text
            nsView.fitField()
        }
    }

    final class Coordinator {
        var parent: InlineTextFieldHost
        init(_ parent: InlineTextFieldHost) {
            self.parent = parent
        }
    }
}
