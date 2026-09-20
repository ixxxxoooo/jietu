import AppKit
import Testing
@testable import Jietu

/// 钉图边框光晕：位置 / 尺寸跟随钉图，且不吃鼠标事件。
///
/// @author ixxxxoooo
@Suite("钉图边框光晕")
struct PinGlowWindowTests {

    /// 造一个和钉图同样配置的无边框面板（不显示，测试只关心几何与层级）。
    private func makePinPanel(frame: NSRect) -> PinPanel {
        PinPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    @Test("光晕窗口按每边 margin 外扩")
    func glowFrameExpandsEverySide() {
        let pin = NSRect(x: 100, y: 200, width: 400, height: 300)
        let glow = PinGlowController.glowFrame(for: pin)
        let margin = PinGlowController.margin
        #expect(glow.minX == pin.minX - margin)
        #expect(glow.minY == pin.minY - margin)
        #expect(glow.width == pin.width + margin * 2)
        #expect(glow.height == pin.height + margin * 2)
    }

    @Test("挂上光晕后：对齐钉图、挂在钉图下面、不吃鼠标")
    func attachedGlowAlignsAndIgnoresMouse() {
        let panel = makePinPanel(frame: NSRect(x: 100, y: 200, width: 400, height: 300))
        let glow = PinGlowController(pinWindow: panel)

        #expect(glow.isAttachedForTesting, "光晕要是钉图的 child window，才会跟着一起移动")
        #expect(glow.ignoresMouseEventsForTesting, "光晕不能拦鼠标，拖动 / 缩放还得落在钉图上")
        #expect(glow.frameForTesting == PinGlowController.glowFrame(for: panel.frame))
    }

    @Test("钉图缩放 / 移动后光晕同步跟随")
    func glowFollowsPinResize() {
        let panel = makePinPanel(frame: NSRect(x: 100, y: 200, width: 400, height: 300))
        let glow = PinGlowController(pinWindow: panel)
        panel.onFrameChanged = { [weak glow] frame in glow?.syncFrame(forPinFrame: frame) }

        let resized = NSRect(x: 100, y: 200, width: 600, height: 450)
        panel.setFrame(resized, display: false)
        #expect(glow.frameForTesting == PinGlowController.glowFrame(for: resized))

        let moved = NSRect(x: 300, y: 400, width: 600, height: 450)
        panel.setFrameOrigin(moved.origin)
        #expect(glow.frameForTesting == PinGlowController.glowFrame(for: moved))
    }

    @Test("收掉光晕后不再是钉图的 child window，也不再留在屏上")
    func detachRemovesChildWindow() {
        let panel = makePinPanel(frame: NSRect(x: 100, y: 200, width: 400, height: 300))
        let glow = PinGlowController(pinWindow: panel)

        glow.detach()
        #expect(!glow.isAttachedForTesting)
        #expect(!glow.isVisibleForTesting, "钉图没了，光晕不能还留在屏上")
    }

    @Test("钉图时按设置决定挂不挂光晕（开关关着就一个窗口都不多）")
    func pinConsultsSetting() {
        let image = TestImage.solidColor(width: 120, height: 80)
        let previous = PinWindowController.isBorderGlowEnabled
        defer {
            PinWindowController.isBorderGlowEnabled = previous
            PinWindowController.closeAllForTesting()
        }

        PinWindowController.isBorderGlowEnabled = { false }
        PinWindowController.pin(image: image, on: NSScreen.main)
        #expect(PinWindowController.pinnedGlowFramesForTesting.isEmpty, "关着就该保持现状：不加任何窗口")

        PinWindowController.isBorderGlowEnabled = { true }
        PinWindowController.pin(image: image, on: NSScreen.main)
        let frames = PinWindowController.pinnedGlowFramesForTesting
        #expect(frames.count == 1, "开着就该给这张钉图挂上光晕")
        if let frame = frames.first {
            let pinFrame = NSRect(
                x: frame.minX + PinGlowController.margin,
                y: frame.minY + PinGlowController.margin,
                width: frame.width - PinGlowController.margin * 2,
                height: frame.height - PinGlowController.margin * 2
            )
            #expect(frame.width > 0 && pinFrame.width > 0, "光晕窗口得是真有尺寸的")
        }
    }

    @Test("光晕真的画出了选区绿：图片边缘外侧一圈是绿的，往外逐渐淡掉")
    func glowRendersGreenHalo() throws {
        let pinFrame = NSRect(x: 0, y: 0, width: 200, height: 150)
        let panel = makePinPanel(frame: pinFrame)
        let glow = PinGlowController(pinWindow: panel)
        let rendered = try renderGlow(glow)

        let margin = Int(PinGlowController.margin)
        let midY = rendered.height / 2
        // 图片右边缘外一点点：柔光最亮的地方，必须明显偏绿。
        let nearEdge = rendered.sample(margin + 200 + 4, midY)
        #expect(nearEdge.a > 0, "边缘外应当有光晕像素")
        #expect(nearEdge.g > nearEdge.r + 25, "光晕应当是绿的：\(nearEdge)")

        // 再往外（贴近窗口边缘）还有余晖，但比紧贴边缘处弱。
        let farEdge = rendered.sample(rendered.width - 1, midY)
        #expect(farEdge.g > farEdge.r, "光晕外围应当仍有绿色余晖：\(farEdge)")
        #expect(farEdge.g < nearEdge.g, "光晕应当往外淡掉：\(farEdge) vs \(nearEdge)")

        // 图片正上方（会被钉图窗口盖住的区域）是实心绿：钉图窗口就在这一层上面。
        let inside = rendered.sample(margin + 100, midY)
        #expect(inside.g > inside.r + 100, "内区是实心绿，钉图窗口盖在上面：\(inside)")
    }

    @Test("光晕窗口改尺寸后画出来的光晕跟着挪（不是只在初始化时算一次）")
    func glowPathsFollowFrameChange() throws {
        let panel = makePinPanel(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        let glow = PinGlowController(pinWindow: panel)

        // 钉图放大到 320x200：光晕该跟着变到新位置，而不是留在原来那圈。
        glow.syncFrame(forPinFrame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let rendered = try renderGlow(glow)

        let margin = Int(PinGlowController.margin)
        let midY = rendered.height / 2
        let newEdge = rendered.sample(margin + 320 + 4, midY)
        #expect(newEdge.g > newEdge.r + 25, "新边缘外应当有绿色光晕：\(newEdge)")
        let oldEdge = rendered.sample(margin + 200 + 4, midY)
        #expect(oldEdge.g > oldEdge.r + 100, "旧边缘的位置现在是图片内区（实心绿）：\(oldEdge)")
    }

    /// 离屏渲染光晕层，逐点取色。
    private func renderGlow(
        _ glow: PinGlowController
    ) throws -> (width: Int, height: Int, sample: (Int, Int) -> (r: Int, g: Int, b: Int, a: Int)) {
        let view = try #require(glow.contentViewForTesting)
        view.layout()
        let layer = try #require(view.layer)
        let width = Int(view.bounds.width)
        let height = Int(view.bounds.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        layer.render(in: context)
        let sample: (Int, Int) -> (r: Int, g: Int, b: Int, a: Int) = { x, y in
            let index = (y * width + x) * 4
            return (
                Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]),
                Int(pixels[index + 3])
            )
        }
        return (width: width, height: height, sample: sample)
    }
}
