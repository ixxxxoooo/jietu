import AppKit
import Testing
@testable import Jietu

@Suite("就地文本输入与选框样式")
@MainActor
struct InlineTextFieldTests {

    @Test("选框线条为粗体且控制点放大")
    func selectionThemeTokens() {
        #expect(Theme.selectionBorderWidth >= 2.0, "选框线条应为粗体线条")
        #expect(Theme.selectionHandleSize >= 10, "控制点圆点应放大")
        #expect(Theme.selectionHandleHitTolerance >= 12, "控制点容差应跟随放大")
    }

    @Test("输入文本时按 Esc 触发退出截图回调")
    func escapeCancelsScreenshot() {
        let field = InlineTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        var cancelFired = false
        field.onCancelScreenshot = {
            cancelFired = true
        }

        // 1. 测试 cancelOperation
        field.cancelOperation(nil)
        #expect(cancelFired, "cancelOperation 应该触发退出截图")

        // 2. 测试 performKeyEquivalent(keyCode 53 = Esc)
        cancelFired = false
        guard let escapeEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else {
            Issue.record("无法构建 Esc 按键事件")
            return
        }

        let handled = field.performKeyEquivalent(with: escapeEvent)
        #expect(handled, "performKeyEquivalent 应消费 Esc 键")
        #expect(cancelFired, "按 Esc 键应触发退出截图")
    }

    @Test("输入文本时 control:textView:doCommandBy 响应 cancelOperation 与 complete")
    func controlTextViewDoCommandBy() {
        let field = InlineTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        var cancelFired = false
        field.onCancelScreenshot = {
            cancelFired = true
        }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        let handledCancel = field.control(
            field,
            textView: textView,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )
        #expect(handledCancel)
        #expect(cancelFired)

        cancelFired = false
        let handledComplete = field.control(
            field,
            textView: textView,
            doCommandBy: #selector(NSResponder.complete(_:))
        )
        #expect(handledComplete)
        #expect(cancelFired)
    }

    @Test("文字输入变化触发通知回调")
    func textChangeNotifies() {
        let field = InlineTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        var changeCount = 0
        field.onTextWidthChange = {
            changeCount += 1
        }

        // 模拟获得焦点并挂载 editor
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(field)
        _ = window.makeFirstResponder(field)
        field.attachEditorObservers()

        if let editor = field.currentEditor() as? NSTextView, let storage = editor.textStorage {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ceshi")
            // 触发 textStorage didProcessEditing
            NotificationCenter.default.post(
                name: NSTextStorage.didProcessEditingNotification,
                object: storage
            )
            #expect(changeCount >= 1, "textStorage 变化应触发 onTextWidthChange")
        }

        field.detachEditorObservers()
    }
}
