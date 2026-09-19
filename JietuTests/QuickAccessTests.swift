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
        let frames: [(String, NSRect)] = QuickAccessAction.imageCard.map {
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
            for action in QuickAccessAction.imageCard {
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
        for action in QuickAccessAction.imageCard {
            let frame = QuickAccessControlsView.frame(of: action, in: tiny)
            #expect(abs(frame.midY - tiny.height / 2) <= 0.5)
        }
    }

    @Test("视频卡（录屏收工）：上排圆盘 + 下排两个胶囊 + 中央播放")
    func videoCardHasDiscsCapsulesAndCenterPlay() {
        let card = CGSize(width: 260, height: 146)
        let frames: [(QuickAccessAction, NSRect)] = QuickAccessAction.videoCard.map {
            ($0, QuickAccessControlsView.frame(of: $0, in: card))
        }
        // 上排三个圆盘 + 下排两个胶囊 + 中央播放 = 6 个
        #expect(frames.count == 6, "上排三个 + 下排两个 + 中央播放")
        #expect(QuickAccessAction.videoCard.contains(.saveVideo), "操作栏要能保存 MP4")
        #expect(QuickAccessAction.videoCard.contains(.exportGif), "操作栏要能导出 GIF")
        #expect(!QuickAccessAction.videoCard.contains(.trimVideo), "裁剪已移除（macOS 预览自带）")
        // 中央「播放」是圆盘
        let play = QuickAccessControlsView.frame(of: .play, in: card)
        #expect(play.width == QuickAccessControlsView.diameter)
        #expect(play.midX == card.width / 2 && play.midY == card.height / 2)
        // saveVideo 和 exportGif 是胶囊（比圆盘宽），其余是圆盘
        for (action, frame) in frames {
            if action == .saveVideo || action == .exportGif {
                #expect(frame.width > QuickAccessControlsView.diameter, "\(action.title) 是胶囊")
            } else {
                #expect(frame.width == QuickAccessControlsView.diameter, "\(action.title) 是圆盘")
            }
            #expect(frame.minX >= 0 && frame.maxX <= card.width, "\(action.title) 越界")
            #expect(frame.minY >= 0 && frame.maxY <= card.height, "\(action.title) 越界")
        }
        for (index, first) in frames.enumerated() {
            for second in frames[(index + 1)...] {
                #expect(!first.1.intersects(second.1), "\(first.0.title) 与 \(second.0.title) 重叠")
            }
        }

        // 位子：上排「复制文件 / 在访达中显示 / 关闭」（工具类圆盘），
        // 下排「MP4(胶囊) / GIF(胶囊)」（格式导出），**中央播放**。
        let copyFile = QuickAccessControlsView.frame(of: .copyFile, in: card)
        let reveal = QuickAccessControlsView.frame(of: .reveal, in: card)
        let close = QuickAccessControlsView.frame(of: .close, in: card)
        let save = QuickAccessControlsView.frame(of: .saveVideo, in: card)
        let gif = QuickAccessControlsView.frame(of: .exportGif, in: card)
        // 上排：copyFile 左上、reveal 上居中、close 右上
        #expect(copyFile.minX < card.width / 2 && copyFile.minY > card.height / 2)
        #expect(reveal.midX == card.width / 2 && reveal.minY > card.height / 2)
        #expect(close.minX > card.width / 2 && close.minY > card.height / 2)
        // 下排：save 左下、gif 右下
        #expect(save.minX < card.width / 2 && save.minY < card.height / 2)
        #expect(gif.minX > card.width / 2 && gif.minY < card.height / 2)
        #expect(QuickAccessAction.play.slot == .center)
    }

    @Test("视频卡最窄也放得下控件（两个胶囊不重叠）")
    func videoCardFitsControlsAtMinimumWidth() {
        // 下排有两个胶囊（MP4/GIF），需要比纯圆盘更宽的下限。
        let minimum = Theme.Size.quickAccessVideoCardMin
        #expect(minimum.width >= 200, "两个胶囊至少要 200pt")
        let card = QuickAccessView.panelSize(
            for: CGSize(width: 90, height: 400), minimum: minimum
        )
        #expect(card.width >= minimum.width)
        let frames = QuickAccessAction.videoCard.map {
            QuickAccessControlsView.frame(of: $0, in: card)
        }
        for (index, first) in frames.enumerated() {
            for second in frames[(index + 1)...] {
                #expect(!first.intersects(second), "最小卡片上控件也不能重叠")
            }
        }
    }

    @Test("视频卡的「保存」把成片交给外面（另存为），且不动原片")
    func videoCardSaveHandsTheFileOut() {
        // 放一个真文件当「成片」：dismiss 之后它必须还在（临时导出文件才删）。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jietu-test-\(UUID().uuidString).mp4")
        try? Data([0x00, 0x01]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = QuickAccessPanelController()
        var saved: URL?
        controller.onSaveVideo = { saved = $0 }
        controller.presentVideo(
            url: url,
            thumbnail: TestImage.solidColor(width: 520, height: 292),
            thumbnailPointSize: CGSize(width: 260, height: 146),
            duration: 12,
            onDisplay: CGMainDisplayID()
        )

        guard let panel = controller.panelsForTesting.last else {
            controller.dismiss()
            Issue.record("浮窗没建起来")
            return
        }
        // SwiftUI 的 `NSViewRepresentable` 要等一次布局 / 绘制才真的挂出子视图。
        panel.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        panel.contentView?.layoutSubtreeIfNeeded()

        guard let controls = findControls(in: panel.contentView) else {
            controller.dismiss()
            Issue.record("没找到浮窗上的图标层")
            return
        }
        #expect(controls.button(for: .saveVideo) != nil, "视频卡上要有「保存」")
        controls.button(for: .saveVideo)?.onClick?()
        #expect(saved == url, "「保存」要把这个成片交出去")

        controller.dismiss()
        #expect(FileManager.default.fileExists(atPath: url.path), "关卡片不能删用户的成片")
    }

    /// 浮窗的图标层藏在 NSHostingView 里，递归找一下。
    private func findControls(in view: NSView?) -> QuickAccessControlsView? {
        guard let view else { return nil }
        if let controls = view as? QuickAccessControlsView { return controls }
        for subview in view.subviews {
            if let found = findControls(in: subview) { return found }
        }
        return nil
    }

    @Test("视频卡时长文本：m:ss，超过一小时才带小时位")
    func videoCardDurationText() {
        #expect(QuickAccessVideoView.durationText(0) == "0:00")
        #expect(QuickAccessVideoView.durationText(12) == "0:12")
        #expect(QuickAccessVideoView.durationText(65.9) == "1:05")
        #expect(QuickAccessVideoView.durationText(600) == "10:00")
        #expect(QuickAccessVideoView.durationText(3661) == "1:01:01")
        // 时长读不出来（0 / NaN）时不能显示 "-1:59" 这种怪东西。
        #expect(QuickAccessVideoView.durationText(-3) == "0:00")
    }

    @Test("视频卡的封面按同一套规则排尺寸：等比、不放大")
    func videoCardUsesTheSameSizingRules() {
        // 1120×720 像素的录屏在 2x 屏上是 560×360 点 → 夹进最大框 260×180。
        let point = CGSize(width: 560, height: 360)
        let card = QuickAccessView.panelSize(for: point)
        let view = QuickAccessVideoView(
            thumbnail: NSImage(size: NSSize(width: 560, height: 360)),
            thumbnailPointSize: point,
            duration: 12,
            cardSize: card,
            onPlay: {}, onReveal: {}, onCopyFile: {}, onSave: {}, onExportGif: {},
            onClose: {},
            onHoverChange: { _ in }, dragProvider: { NSItemProvider() }
        )
        #expect(card == CGSize(width: 260, height: 167))
        #expect(view.thumbnailDisplaySize == card, "大封面正好铺满卡片")

        // 小录屏（300×200 像素 → 150×100 点）不放大。
        let small = CGSize(width: 150, height: 100)
        let smallCard = QuickAccessView.panelSize(for: small)
        let smallView = QuickAccessVideoView(
            thumbnail: NSImage(size: NSSize(width: 150, height: 100)),
            thumbnailPointSize: small,
            duration: 3,
            cardSize: smallCard,
            onPlay: {}, onReveal: {}, onCopyFile: {}, onSave: {}, onExportGif: {},
            onClose: {},
            onHoverChange: { _ in }, dragProvider: { NSItemProvider() }
        )
        #expect(smallView.thumbnailDisplaySize == small)
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

        button.mouseDown(with: TestNSEvent.mouse(.leftMouseDown, at: NSPoint(x: 14, y: 14)))
        #expect(button.isPressedNow, "按下反馈必须当场就位，不能等抬起")

        button.mouseUp(with: TestNSEvent.mouse(.leftMouseUp, at: NSPoint(x: 14, y: 14)))
        #expect(clicked == 1)
        #expect(!button.isPressedNow)
    }

    @Test("拖到按钮外面松手不触发动作")
    func buttonIgnoresReleaseOutside() {
        let button = GlassControlButton(symbol: "pin", tooltip: "钉图")
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        var clicked = 0
        button.onClick = { clicked += 1 }

        button.mouseDown(with: TestNSEvent.mouse(.leftMouseDown, at: NSPoint(x: 14, y: 14)))
        button.mouseUp(with: TestNSEvent.mouse(.leftMouseUp, at: NSPoint(x: 80, y: 80)))
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

    @Test("点击浮窗卡片进入预览不销毁浮窗")
    func clickingCardToAnnotateKeepsCardAlive() {
        let controller = QuickAccessPanelController()
        let image = TestImage.solidBlack(side: 100)
        var annotatedImage: CGImage?
        var annotatedCard: UUID?
        controller.onAnnotate = { image, cardID in
            annotatedImage = image
            annotatedCard = cardID
        }

        controller.present(
            image: image,
            onDisplay: CGMainDisplayID(),
            saveDirectory: FileManager.default.temporaryDirectory
        )

        #expect(controller.isVisible)
        #expect(controller.panelsForTesting.count == 1)

        // 模拟外部点击卡片触发 onAnnotate：真实路径会把卡片自己的 id 一起带出去
        // （编辑确认后要按这个 id 让旧卡片让位）。
        let card = controller.entryIDsForTesting[0]
        controller.onAnnotate?(image, card)
        #expect(annotatedImage != nil)
        #expect(annotatedCard == card)
        // 浮窗依然存在：用户取消编辑时那张卡片还得在
        #expect(controller.isVisible)
        #expect(controller.panelsForTesting.count == 1)

        // 只有手动关闭或超时才销毁
        controller.dismiss()
        #expect(!controller.isVisible)
    }

    @Test("原地编辑确认后：按 id 收掉被编辑的那张卡片，别的不动")
    func dismissEditedCardKeepsOthers() {
        let controller = QuickAccessPanelController()
        // 别让自动关闭把卡片收走，否则断言到的是超时那条路。
        controller.autoCloseDelay = 0
        let image = TestImage.solidBlack(side: 100)
        for _ in 0..<2 {
            controller.present(
                image: image,
                onDisplay: CGMainDisplayID(),
                saveDirectory: FileManager.default.temporaryDirectory
            )
        }
        #expect(controller.panelsForTesting.count == 2)

        let ids = controller.entryIDsForTesting
        controller.dismiss(card: ids[0], animated: false)

        #expect(controller.panelsForTesting.count == 1, "只收掉被编辑的那张")
        #expect(controller.entryIDsForTesting == [ids[1]])

        controller.dismiss()
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
