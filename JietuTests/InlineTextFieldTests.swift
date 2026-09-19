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

        #expect(field.isEditable, "InlineTextField 必须可编辑")
        guard let editor = field.currentEditor() as? NSTextView, let storage = editor.textStorage else {
            Issue.record("获取焦点后必须成功挂载 currentEditor")
            return
        }

        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ceshi")
        // 触发 textStorage didProcessEditing
        NotificationCenter.default.post(
            name: NSTextStorage.didProcessEditingNotification,
            object: storage
        )
        #expect(changeCount >= 1, "textStorage 变化应触发 onTextWidthChange")
        #expect(field.currentText() == "ceshi", "currentText 应返回当前输入的文本")

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

    @Test("标注特效所见即所得：背景底板、高对比文字反色与内边距")
    func calloutStyleAndContrast() {
        let field = InlineTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))

        // 1. 深色背景（如深红），文字应选用高对比白色
        field.applyStyle(
            fontSize: 16,
            color: RGBAColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1.0),
            hasStroke: false,
            hasCallout: true
        )
        #expect(field.layer?.backgroundColor != nil, "开启标注应有底板背景色")
        #expect(field.textColor == NSColor.white, "深色背景下文字应为白色")
        let cell = field.cell as? InlineTextFieldCell
        #expect(cell != nil)
        #expect(cell!.paddingH >= 6, "标注特效应包含水平内边距")
        #expect(cell!.paddingV >= 3, "标注特效应包含垂直内边距")

        // 2. 浅色背景（如亮黄），文字应选用高对比黑色
        field.applyStyle(
            fontSize: 16,
            color: RGBAColor(red: 0.95, green: 0.95, blue: 0.1, alpha: 1.0),
            hasStroke: false,
            hasCallout: true
        )
        #expect(field.textColor == NSColor.black, "浅色背景下文字应为黑色")

        // 3. 关闭标注：底板背景清除，文字恢复为标注色
        field.applyStyle(
            fontSize: 16,
            color: RGBAColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1.0),
            hasStroke: false,
            hasCallout: false
        )
        #expect(field.layer?.backgroundColor == nil, "关闭标注应无底板背景")
        #expect(cell!.paddingH == 2)
        #expect(cell!.paddingV == 0)
    }

    @Test("fitToOrigin 在 Flipped 和非 Flipped 下准确对齐点击原点并计算内边距")
    func fitToOriginAdjustsForCallout() {
        let field = InlineTextField(frame: .zero)
        field.stringValue = "测试文字"
        field.applyStyle(
            fontSize: 14,
            color: .red,
            hasStroke: false,
            hasCallout: true
        )

        let origin = CGPoint(x: 100, y: 200)
        let cell = field.cell as! InlineTextFieldCell
        let padH = cell.paddingH
        let padV = cell.paddingV

        // Flipped（SwiftUI 坐标系）
        field.fitToOrigin(origin, isFlipped: true)
        #expect(abs(field.frame.origin.x - (origin.x - padH)) < 0.001)
        #expect(abs(field.frame.origin.y - (origin.y - padV)) < 0.001)

        // 非 Flipped（AppKit 坐标系）
        field.fitToOrigin(origin, isFlipped: false)
        #expect(abs(field.frame.origin.x - (origin.x - padH)) < 0.001)
        #expect(field.frame.origin.y < origin.y)
    }

    @Test("圆圈工具下 ShapeFillModePicker 支持圆形图标")
    func shapeFillModePickerCircleSupport() {
        let pickerCircle = ShapeFillModePicker(selectedMode: .constant(.opaque), isCircle: true)
        #expect(pickerCircle.isCircle == true, "应支持圆形填充模式图标")
        let pickerRect = ShapeFillModePicker(selectedMode: .constant(.none), isCircle: false)
        #expect(pickerRect.isCircle == false, "默认应为矩形图标")
    }

    @Test("InlineTextFieldContainerView 支持样式应用、文本同步与提交取消")
    func inlineTextFieldContainerBehavior() {
        let container = InlineTextFieldContainerView()
        container.origin = CGPoint(x: 50, y: 80)
        var committedText: String?
        var cancelled = false
        var textChanged: String?

        container.onCommit = { text in committedText = text }
        container.onCancel = { cancelled = true }
        container.onTextChange = { text in textChanged = text }

        container.textField.stringValue = "你好"
        container.applyStyle(
            fontSize: 18,
            color: .red,
            hasStroke: true,
            hasCallout: false
        )

        #expect(container.textField.font?.pointSize == 18)
        #expect(container.textField.stringValue == "你好")

        container.textField.onTextChanged?("测试输入")
        #expect(textChanged == "测试输入")

        container.textField.onCommit?()
        #expect(committedText == "你好")

        container.textField.onCancel?()
        #expect(cancelled == true)
    }

    @Test("填充图形在实心/半透明下点击内部命中，线框模式下仅边缘命中")
    func filledShapeHitTesting() {
        let rect = CGRect(x: 10, y: 10, width: 100, height: 100)
        let strokeRect = Annotation(kind: .rectangle(rect), color: .red, shapeFillMode: .none)
        let filledRect = Annotation(kind: .rectangle(rect), color: .red, shapeFillMode: .opaque)

        let insideCenter = CGPoint(x: 60, y: 60)
        let onBorder = CGPoint(x: 10, y: 50)

        // 内部中心点：线框不命中，填充命中
        #expect(!strokeRect.contains(insideCenter, tolerance: 2))
        #expect(filledRect.contains(insideCenter, tolerance: 2))

        // 边缘点：两者皆命中
        #expect(strokeRect.contains(onBorder, tolerance: 4))
        #expect(filledRect.contains(onBorder, tolerance: 4))
    }

    @Test("InlineTextField 结束编辑（失去焦点）自动提交文本")
    func controlTextDidEndEditingTriggersCommit() {
        let field = InlineTextField(frame: .zero)
        var committed = false
        field.onCommit = {
            committed = true
        }
        let notification = Notification(name: NSControl.textDidEndEditingNotification, object: field)
        field.controlTextDidEndEditing(notification)
        #expect(committed == true)
    }
}
