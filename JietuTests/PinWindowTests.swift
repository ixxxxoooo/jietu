import AppKit
import Testing
@testable import Jietu

@Suite("钉图窗口与交互")
struct PinWindowTests {

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
        let close = PinGlassCircleButton(
            diameter: 28, systemSymbolName: "xmark", tooltip: "关闭"
        )
        let liveText = PinGlassCircleButton(
            diameter: 28, systemSymbolName: "text.viewfinder", tooltip: "实况文本"
        )
        #expect(close.followsSystemAppearance)
        #expect(liveText.followsSystemAppearance)
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
