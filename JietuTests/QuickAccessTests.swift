import AppKit
import Testing
@testable import Jietu

@Suite("浮窗图标层")
struct QuickAccessTests {

    private static let cardSize = CGSize(width: 240, height: 180)

    @Test("四角圆盘 + 中央胶囊：贴边 8pt、直径 28，且互不重叠")
    func controlFramesAreLaidOutAtCorners() {
        let inset = QuickAccessControlsView.edgeInset
        let radius = QuickAccessControlsView.diameter / 2

        let close = QuickAccessControlsView.frame(of: .close, in: Self.cardSize)
        let pin = QuickAccessControlsView.frame(of: .pin, in: Self.cardSize)
        let annotate = QuickAccessControlsView.frame(of: .annotate, in: Self.cardSize)
        let copy = QuickAccessControlsView.frame(of: .copy, in: Self.cardSize)
        let save = QuickAccessControlsView.frame(of: .save, in: Self.cardSize)

        // 右上 / 右下 / 左下 / 左上
        #expect(close.maxX == Self.cardSize.width - inset)
        #expect(close.maxY == Self.cardSize.height - inset)
        #expect(pin.maxX == Self.cardSize.width - inset)
        #expect(pin.minY == inset)
        #expect(annotate.minX == inset)
        #expect(annotate.minY == inset)
        #expect(copy.minX == inset)
        #expect(copy.maxY == Self.cardSize.height - inset)
        #expect(close.width == QuickAccessControlsView.diameter)
        #expect(annotate.height == QuickAccessControlsView.diameter)
        #expect(close.midX == Self.cardSize.width - inset - radius)

        // 中央「保存」是胶囊，横向居中
        #expect(save.midX == Self.cardSize.width / 2)
        #expect(save.midY == Self.cardSize.height / 2)
        #expect(save.width > QuickAccessControlsView.diameter)
        #expect(save.height == GlassControlButton.preferredSize().height)

        // 五个控件两两不重叠（尺寸不同的卡片共用同一套交互，重叠就等于点不准）
        let frames: [(String, NSRect)] = [
            ("关闭", close), ("钉图", pin), ("标注", annotate), ("复制", copy), ("保存", save),
        ]
        for (index, first) in frames.enumerated() {
            for second in frames[(index + 1)...] {
                #expect(!first.1.intersects(second.1), "\(first.0) 与 \(second.0) 重叠")
            }
        }
    }

    @Test("卡片尺寸：极端宽高比被最小尺寸夹住，比例正常的原样算")
    func panelSizeClampsToMinimum() {
        // 正常比例：只受上限约束（800×600 按 0.3 缩到 240×180）。
        #expect(QuickAccessView.panelSize(for: CGSize(width: 800, height: 600))
            == CGSize(width: 240, height: 180))
        #expect(QuickAccessView.panelSize(for: CGSize(width: 1000, height: 800))
            == CGSize(width: 225, height: 180))

        // 竖长截图（600×1200）：按比例只有 90 宽 → 夹到最小宽度，图片居中留白。
        let tall = QuickAccessView.panelSize(for: CGSize(width: 600, height: 1200))
        #expect(tall.width == Theme.Size.quickAccessCardMin.width)
        #expect(tall.height == 180)

        // 超宽截图（1600×600）：按比例只有 98 高 → 夹到最小高度。
        let wide = QuickAccessView.panelSize(for: CGSize(width: 1600, height: 600))
        #expect(wide.width == 260)
        #expect(wide.height == Theme.Size.quickAccessCardMin.height)

        // 极端（4000×100）：两个方向都被夹住。
        let extreme = QuickAccessView.panelSize(for: CGSize(width: 4000, height: 100))
        #expect(extreme == CGSize(width: 260, height: Theme.Size.quickAccessCardMin.height))
    }

    @Test("小图不放大：卡片按最小尺寸兜底，图片保持原始点尺寸")
    func tinyImageIsNotUpscaled() {
        // 40×20 像素（2x 屏 = 20×10 点）的小截图。
        let tiny = CGSize(width: 20, height: 10)
        let card = QuickAccessView.panelSize(for: tiny)
        #expect(card == Theme.Size.quickAccessCardMin, "小卡片尺寸兜到最小框")

        let view = QuickAccessView(
            image: NSImage(size: NSSize(width: 20, height: 10)),
            imagePointSize: tiny,
            cardSize: card,
            onCopy: {}, onSave: {}, onAnnotate: {}, onPin: {}, onClose: {},
            onHoverChange: { _ in }, dragProvider: { NSItemProvider() }
        )
        #expect(view.imageDisplaySize == tiny, "小图按原始点尺寸显示，不放大")
    }

    @Test("大图正好填满卡片：显示尺寸 = 卡片尺寸")
    func largeImageFillsCard() {
        let pointSize = CGSize(width: 400, height: 300)
        let card = QuickAccessView.panelSize(for: pointSize)
        let view = QuickAccessView(
            image: NSImage(size: NSSize(width: 400, height: 300)),
            imagePointSize: pointSize,
            cardSize: card,
            onCopy: {}, onSave: {}, onAnnotate: {}, onPin: {}, onClose: {},
            onHoverChange: { _ in }, dragProvider: { NSItemProvider() }
        )
        #expect(view.imageDisplaySize == card)
    }

    @Test("最小尺寸的卡片上，五个图标互不重叠、都在卡片里")
    func minimumCardStillFitsControls() {
        let card = Theme.Size.quickAccessCardMin
        let frames: [(String, NSRect)] = QuickAccessAction.allCases.map {
            ($0.title, QuickAccessControlsView.frame(of: $0, in: card))
        }
        for (index, first) in frames.enumerated() {
            for second in frames[(index + 1)...] {
                #expect(!first.1.intersects(second.1), "\(first.0) 与 \(second.0) 在最小卡片上重叠")
            }
            #expect(first.1.minX >= 0 && first.1.maxX <= card.width)
            #expect(first.1.minY >= 0 && first.1.maxY <= card.height)
        }
    }

    @Test("各种真实卡片尺寸下，按钮都留在卡片里")
    func controlsStayInsideRealisticCards() {
        // 240×180 = 4:3、90×180 = 600×1200 的竖图、260×98 = 1600×600 的宽图。
        for card in [CGSize(width: 240, height: 180), CGSize(width: 90, height: 180),
                     CGSize(width: 260, height: 98)] {
            for action in QuickAccessAction.allCases {
                let frame = QuickAccessControlsView.frame(of: action, in: card)
                #expect(frame.minX >= -0.001, "\(action) 越出卡片左边界（卡片 \(card)）")
                #expect(frame.maxX <= card.width + 0.001, "\(action) 越出卡片右边界（卡片 \(card)）")
                #expect(frame.minY >= -0.001, "\(action) 越出卡片下边界（卡片 \(card)）")
                #expect(frame.maxY <= card.height + 0.001, "\(action) 越出卡片上边界（卡片 \(card)）")
            }
        }
    }

    @Test("卡片比控件还小时按钮居中（对称溢出），不会被推到一边")
    func controlsCenterOnDegenerateCard() {
        // 2000×100 的截图换算出来只有十几点高，装不下 28pt 的圆盘。
        let tiny = CGSize(width: 260, height: 13)
        for action in QuickAccessAction.allCases {
            let frame = QuickAccessControlsView.frame(of: action, in: tiny)
            #expect(abs(frame.midY - tiny.height / 2) <= 0.5)
        }
    }

    @Test("按钮的 hitTest 收父视图坐标系的点（不靠原点的按钮也得命中）")
    func buttonHitTestUsesSuperviewCoordinates() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let button = GlassControlButton(symbol: "xmark", tooltip: "关闭")
        button.frame = NSRect(x: 204, y: 144, width: 28, height: 28)
        host.addSubview(button)

        // 传的是**父视图坐标系**里的按钮中心：204+14 / 144+14
        #expect(button.hitTest(NSPoint(x: 218, y: 158)) === button)
        // 父视图里别处：不该命中
        #expect(button.hitTest(NSPoint(x: 10, y: 10)) == nil)
        // 直接 `bounds.contains(point)` 是错的口径：按钮 bounds 只有 28×28，
        // 父视图里的 (218,158) 换到按钮自己的坐标是 (14,14)——命中与否必须按后者判。
        #expect(button.hitTest(NSPoint(x: 20, y: 20)) == nil)
    }

    @Test("悬停之外不吃事件：卡片本体的点击/拖拽照旧落到下层")
    func controlsIgnoreEventsUntilHovering() {
        let (host, controls) = makeHostedControls()
        let closeCenter = NSPoint(x: 218, y: 158)

        #expect(controls.hitTest(closeCenter) == nil, "没悬停就吃事件，四角拖拽导出会变死区")

        controls.mouseEntered(with: fakeEnterExitEvent(.mouseEntered, at: NSPoint(x: 120, y: 90)))
        #expect(controls.isHovering)
        #expect(controls.hitTest(closeCenter) === controls.button(for: .close))
        // 悬停时，卡片空白处仍然让给下层（否则点击进标注就没了）
        #expect(controls.hitTest(NSPoint(x: 120, y: 47)) == nil)

        controls.mouseExited(with: fakeEnterExitEvent(.mouseExited, at: NSPoint(x: 120, y: 47)))
        #expect(!controls.isHovering)
        #expect(controls.hitTest(closeCenter) == nil)
        _ = host
    }

    @Test("按钮首击即响应：按下当场给反馈，动作在抬起时发生")
    func buttonRespondsOnMouseDown() {
        let button = GlassControlButton(symbol: "pin", tooltip: "钉图")
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        var clicked = 0
        button.onClick = { clicked += 1 }

        #expect(button.acceptsFirstMouse(for: nil), "非激活浮窗上的第一下点击也要直接生效")
        #expect(!button.isPressedNow)

        button.mouseDown(with: fakeMouseEvent(.leftMouseDown, at: NSPoint(x: 14, y: 14)))
        #expect(button.isPressedNow, "按下反馈必须当场就位，不能等抬起")

        button.mouseUp(with: fakeMouseEvent(.leftMouseUp, at: NSPoint(x: 14, y: 14)))
        #expect(clicked == 1)
        #expect(!button.isPressedNow)
    }

    @Test("拖到按钮外面松手不触发动作")
    func buttonIgnoresReleaseOutside() {
        let button = GlassControlButton(symbol: "pin", tooltip: "钉图")
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        var clicked = 0
        button.onClick = { clicked += 1 }

        button.mouseDown(with: fakeMouseEvent(.leftMouseDown, at: NSPoint(x: 14, y: 14)))
        button.mouseUp(with: fakeMouseEvent(.leftMouseUp, at: NSPoint(x: 80, y: 80)))
        #expect(clicked == 0)
    }

    @Test("胶囊按钮真的带文字（图标 + 文字），圆盘按钮不带")
    func capsuleCarriesItsLabel() {
        let capsule = GlassControlButton(
            symbol: "square.and.arrow.down", labelText: "保存", tooltip: "保存"
        )
        #expect(capsule.renderedLabel == "保存")
        #expect(capsule.preferredSize.width > GlassControlButton.preferredSize().width)
        #expect(capsule.preferredSize.height == GlassControlButton.preferredSize().height)

        let disc = GlassControlButton(symbol: "xmark", tooltip: "关闭")
        #expect(disc.renderedLabel.isEmpty)
        #expect(disc.preferredSize == NSSize(width: 28, height: 28))
    }

    @Test("浮窗图标与钉图图标是同一套：尺寸、玻璃配方一致")
    func floatingControlsShareThePinButtonStyle() {
        let disc = GlassControlButton(symbol: "xmark", tooltip: "关闭")
        #expect(disc.followsSystemAppearance)
        #expect(QuickAccessControlsView.diameter == disc.preferredSize.width)
        // 钉图那两个按钮也是 28pt：同一套图标系统不该差一档
        #expect(QuickAccessControlsView.diameter == 28)
    }

    // MARK: - Helpers

    private func makeHostedControls() -> (NSView, QuickAccessControlsView) {
        let host = NSView(frame: NSRect(origin: .zero, size: Self.cardSize))
        let controls = QuickAccessControlsView()
        controls.frame = host.bounds
        host.addSubview(controls)
        controls.layout()
        return (host, controls)
    }

    private func fakeMouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
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

    private func fakeEnterExitEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
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
}
