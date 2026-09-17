import AppKit
import Testing
@testable import Jietu

@Suite("钉图窗口与交互")
struct PinWindowTests {

    private func enterExit(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            trackingNumber: 1,
            userData: nil
        )!
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        )!
    }

    private func createTestImage(width: Int = 200, height: Int = 150) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(NSColor.red.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test("钉图按钮跟随系统外观：与浮窗/授权面板同款玻璃，不再固定深色")
    func pinButtonFollowsSystemAppearance() {
        let close = GlassControlButton(symbol: "xmark", diameter: 28, tooltip: "关闭")
        let liveText = GlassControlButton(
            symbol: "text.viewfinder", diameter: 28, tooltip: "实况文本"
        )
        #expect(close.followsSystemAppearance)
        #expect(liveText.followsSystemAppearance)
    }

    @Test("实况文本按钮点亮后换成居中的绿色对勾，再点一次还原")
    func pinLiveTextButtonSwapsToGreenCheckmarkWhenActive() {
        let button = GlassControlButton(
            symbol: "text.viewfinder", diameter: 28, tooltip: "实况文本"
        )
        #expect(button.renderedSymbolName == "text.viewfinder")
        // 未点亮：黑 / 白墨，三通道相等（灰度）。
        let off = button.renderedIconTint?.usingColorSpace(.sRGB)
        #expect(abs((off?.greenComponent ?? 1) - (off?.redComponent ?? 0)) < 0.05)

        button.isActive = true
        #expect(button.renderedSymbolName == "checkmark")
        // 点亮：明显偏绿。具体数值交给系统绿，这里只认「绿远大于红」。
        let lit = button.renderedIconTint?.usingColorSpace(.sRGB)
        #expect((lit?.greenComponent ?? 0) - (lit?.redComponent ?? 0) > 0.3)

        button.isActive = false
        #expect(button.renderedSymbolName == "text.viewfinder")
    }

    @Test("预览卡片外框：截图不贴边，四面各留一圈 inset")
    func pinContentIsInsetByCardFrame() {
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: createTestImage())
        view.layout()
        #expect(
            view.contentRectForTesting
                == NSRect(
                    x: PreviewCard.inset, y: PreviewCard.inset,
                    width: 200 - PreviewCard.inset * 2,
                    height: 150 - PreviewCard.inset * 2
                )
        )
    }

    @Test("左下角「翻译」按钮：悬停出现、点击把原文交给 macOS 翻译")
    func translateButtonHandsTextToSystemTranslation() {
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), image: createTestImage())
        view.layout()
        view.mouseEntered(with: enterExit(.mouseEntered, at: NSPoint(x: 200, y: 150)))

        guard let button = view.translateButtonForTesting else {
            Issue.record("没有左下角「翻译」按钮")
            return
        }
        #expect(!button.isHidden, "悬停后翻译按钮应当出现")
        #expect(button.renderedLabel == "翻译")
        #expect(view.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button, "点击必须落在按钮上，不是边缘缩放手柄")

        // 预置原文（真跑一次 OCR 要几百毫秒，这里只验接线）。
        view.presetRecognizedText("System Requirements")
        button.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: button.frame.midX, y: button.frame.midY)))
        button.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: button.frame.midX, y: button.frame.midY)))

        #expect(view.isTranslationHostAttached, "点「翻译」应当把系统翻译面板的宿主挂上")
        #expect(view.presentedTranslationText == "System Requirements")
    }

    @Test("右下角「识别文本」点亮后换成 macOS 那种蓝底实心，关掉回普通玻璃")
    func liveTextButtonTurnsAccentFilledWhileOn() {
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), image: createTestImage())
        guard let button = view.liveTextButtonForTesting else {
            Issue.record("没有右下角「识别文本」按钮")
            return
        }
        #expect(button.prominence == .glass)
        #expect(!button.showsAccentFill, "关着的时候是普通玻璃圆盘")

        view.toggleLiveText()
        #expect(view.liveTextButtonForTesting?.prominence == .accent)
        #expect(view.liveTextButtonForTesting?.showsAccentFill == true)
        // 蓝底上是白图标：不是墨色，也不换勾（macOS 那颗钮也不换图标）。
        #expect(view.liveTextButtonForTesting?.renderedSymbolName == "text.viewfinder")

        view.toggleLiveText()
        #expect(view.liveTextButtonForTesting?.prominence == .glass)
        #expect(view.liveTextButtonForTesting?.showsAccentFill == false)
    }

    @Test("PinPanel 具备成为 Key 窗口的能力且去除了 nonactivatingPanel")
    func pinPanelCanBecomeKey() {
        let panel = PinPanel(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 150),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        #expect(panel.canBecomeKey == true)
        #expect(panel.canBecomeMain == true)
        #expect(!panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test("PinContentView 响应 ⌘W 快捷键触发 onRequestClose")
    func pinContentViewHandlesCommandW() {
        let image = createTestImage()
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: image)
        var closeCalled = false
        view.onRequestClose = {
            closeCalled = true
        }

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        )!

        let handled = view.performKeyEquivalent(with: event)
        #expect(handled == true)
        #expect(closeCalled == true)
    }

    @Test("PinContentView 响应 Esc (keyCode 53) 触发 onRequestClose")
    func pinContentViewHandlesEsc() {
        let image = createTestImage()
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: image)
        var closeCalled = false
        view.onRequestClose = {
            closeCalled = true
        }

        let event = NSEvent.keyEvent(
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
        )!

        view.keyDown(with: event)
        #expect(closeCalled == true)
    }

    @Test("PinPanel performKeyEquivalent 兜底处理 ⌘W 并触发关闭")
    func pinPanelHandlesCommandWFallback() {
        let panel = PinPanel(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 150),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let image = createTestImage()
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: image)
        panel.contentView = view

        var closeCalled = false
        view.onRequestClose = {
            closeCalled = true
        }

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        )!

        let handled = panel.performKeyEquivalent(with: event)
        #expect(handled == true)
        #expect(closeCalled == true)
    }

    @Test("PinPanel cancelOperation 响应 Esc 并触发关闭")
    func pinPanelHandlesCancelOperation() {
        let panel = PinPanel(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 150),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let image = createTestImage()
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: image)
        panel.contentView = view

        var closeCalled = false
        view.onRequestClose = {
            closeCalled = true
        }

        panel.cancelOperation(nil)
        #expect(closeCalled == true)
    }

    @Test("左上角「编辑」按钮可点击并触发 onRequestEdit（回到标注编辑器）")
    func editButtonTriggersEdit() {
        let image = createTestImage()
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: image)
        view.layout()

        var editCalled = false
        view.onRequestEdit = { editCalled = true }

        view.mouseEntered(with: enterExit(.mouseEntered, at: NSPoint(x: 100, y: 75)))

        // 左上角编辑按钮中心：x = 8 + 14 = 22，y = 150 - 8 - 14 = 128。
        let center = NSPoint(x: 22, y: 128)
        guard let button = view.hitTest(center) else {
            Issue.record("未命中左上角编辑按钮")
            return
        }
        // 命中对象必须是按钮本身（命中 view 就会变成拖拽 / 缩放边缘）。
        #expect(button !== view)
        #expect(button.acceptsFirstMouse(for: nil))

        button.mouseDown(with: mouseEvent(.leftMouseDown, at: center))
        button.mouseUp(with: mouseEvent(.leftMouseUp, at: center))
        #expect(editCalled)
    }

    @Test("右上角关闭按钮区域优先响应点击，不被边缘缩放手柄劫持")
    func closeButtonHitTestingPriority() {
        let image = createTestImage()
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: image)
        view.layout()

        // 模拟鼠标移入触发显示
        let enterEvent = NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: 100, y: 75),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            trackingNumber: 1,
            userData: nil
        )!
        view.mouseEntered(with: enterEvent)

        // 右上角关闭按钮中心点：x = 200 - 8 - 14 = 178, y = 150 - 8 - 14 = 128
        let closeCenter = NSPoint(x: 178, y: 128)
        let hit = view.hitTest(closeCenter)

        // 命中对象应该是关闭按钮及其宿主内部视图，绝不能是 view 本身（若是 view 本身就会误触发拖拽调整）
        #expect(hit != nil)
        #expect(hit !== view)
    }

    @Test("关闭按钮支持首击响应 (acceptsFirstMouse = true)")
    func closeButtonAcceptsFirstMouse() {
        let image = createTestImage()
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: image)
        view.layout()

        let enterEvent = NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: 100, y: 75),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            trackingNumber: 1,
            userData: nil
        )!
        view.mouseEntered(with: enterEvent)

        let closeCenter = NSPoint(x: 178, y: 128)
        let hit = view.hitTest(closeCenter)
        #expect(hit?.acceptsFirstMouse(for: nil) == true)
    }

    @Test("单次点击关闭按钮立即触发关闭，无需二次点击")
    func closeButtonSingleClickTriggersClose() {
        let image = createTestImage()
        let view = PinContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 150), image: image)
        view.layout()

        var closeCalled = false
        view.onRequestClose = { closeCalled = true }

        let enterEvent = NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: 100, y: 75),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            trackingNumber: 1,
            userData: nil
        )!
        view.mouseEntered(with: enterEvent)

        let closeCenter = NSPoint(x: 178, y: 128)
        guard let closeButton = view.hitTest(closeCenter) else {
            Issue.record("未命中关闭按钮")
            return
        }

        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: closeCenter,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!
        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: closeCenter,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0.0
        )!

        closeButton.mouseDown(with: downEvent)
        closeButton.mouseUp(with: upEvent)

        #expect(closeCalled == true)
    }
}
