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

    @Test("窗口模式下点击窗口直接截取并进入原地编辑")
    func windowClickEntersInlineAnnotating() {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let snapshot = DisplaySnapshot(
            displayID: screen.jietu_displayID ?? 1,
            screenFrameInPoints: screen.frame,
            nominalScaleFactor: 2,
            image: TestImage.solidBlack(side: 100)
        )
        let localWindowRect = CGRect(x: 50, y: 50, width: 400, height: 300)
        let cgWindowRect = DisplayGeometry.cgRect(fromLocal: localWindowRect, screen: screen)
        let windowInfo = WindowInfo(
            windowID: 42,
            ownerPID: 100,
            ownerName: "Finder",
            title: "Documents",
            layer: 0,
            frameInCGPoints: cgWindowRect
        )
        let session = CaptureSession(snapshots: [snapshot], windows: [windowInfo])
        let view = OverlayCanvasView(
            snapshot: snapshot,
            session: session,
            displayIndex: 1,
            displayCount: 1
        )
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.inlineMode = true
        view.isWindowOnlyMode = true
        view.armInput(after: 0)

        // 模拟鼠标移动到窗口内部以选中 hoveredWindow
        let point = CGPoint(x: 100, y: 100)
        view.mouseMoved(with: NSEvent.mouseEvent(
            with: .mouseMoved,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!)

        // 模拟点击
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!

        view.mouseDown(with: downEvent)
        view.mouseUp(with: upEvent)

        #expect(view.isAnnotationPhase, "点击窗口后应直接进入原地标注态")
        #expect(view.debugSelection != nil, "选区应被置为该窗口矩形")
    }
}
