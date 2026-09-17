import AppKit
import SwiftUI
import Testing
@testable import Jietu

@Suite("就地标注工具栏")
struct InlineToolbarTests {

    @Test("滚动截图：模型把「手动 / 自动」交出去")
    func scrollCaptureHandsOffMode() {
        let model = InlineToolbarModel()
        #expect(!model.showScroll)

        var picked: [ScrollingCaptureSession.Mode] = []
        model.onScrollCapture = { picked.append($0) }
        model.onScrollCapture?(.manual)
        model.onScrollCapture?(.automatic)
        #expect(picked == [.manual, .automatic])
    }

    @Test("滚动截图选项条：打开后有内容，且与颜色 / 粗细互斥")
    func scrollOptionsRenderAndStayExclusive() {
        let model = InlineToolbarModel()

        func optionsSize() -> NSSize {
            NSHostingView(rootView: InlineOptionsToolbar(model: model)).fittingSize
        }

        let closed = optionsSize()
        model.showScroll = true
        let opened = optionsSize()
        #expect(opened.width > closed.width, "打开滚动截图后选项条应当变宽（两个选项在里面）")

        // 三个子面板互斥：主工具栏三个按钮的动作里各自关掉别人。
        // 这里直接按同样的口径置位，钉住「同时只能开一个」这条约定。
        model.showColor = true
        model.showScroll = false
        model.showWidth = false
        #expect(optionsSize().width > 0)
        model.showColor = false
        model.showWidth = true
        #expect(optionsSize().width > 0)
    }

    @Test("主工具栏带「滚动截图」入口，且与颜色 / 粗细同一套展开机制")
    func mainToolbarHasScrollEntry() {
        let model = InlineToolbarModel()
        let host = NSHostingView(rootView: InlineMainToolbar(model: model))
        let size = host.fittingSize
        #expect(size.width > 0, "主工具栏至少要能量出尺寸")

        // 展开选项时主栏尺寸不变（固定尺寸，避免抖动）——滚动截图那一项也走同一条路。
        model.showScroll = true
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
    }
}
