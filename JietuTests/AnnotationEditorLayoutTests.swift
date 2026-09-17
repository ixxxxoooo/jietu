import AppKit
import SwiftUI
import Testing

@testable import Jietu

/// 标注编辑器的窗口最小宽度必须容得下工具栏，否则右边的按钮会被窗口裁掉。
///
/// @author ixxxxoooo
@Suite("标注编辑器布局")
@MainActor
struct AnnotationEditorLayoutTests {
    /// SwiftUI 报出来的最小尺寸就是「工具栏一行放得下」所需的宽度。
    private func measuredMinimumWidth() -> CGFloat {
        let image = TestImage.solidBlack(side: 64)
        let view = AnnotationEditorView(
            baseImage: image,
            inline: true,
            onCopy: { _ in },
            onSave: { _ in },
            onPin: { _, _ in },
            onClose: {}
        )
        return NSHostingView(rootView: view).fittingSize.width
    }

    @Test("工具栏放得进最小窗口宽度")
    func toolbarFitsInMinimumWidths() {
        let needed = measuredMinimumWidth()
        #expect(needed <= AnnotationEditorView.toolbarMinWidth)
        #expect(needed <= AnnotationEditorView.minInlineWidth)
        #expect(needed <= AnnotationEditorView.minWindowWidth)
    }

    @Test("原地编辑窗口再窄也留够工具栏宽度")
    func inlineWindowKeepsToolbarWidth() {
        #expect(AnnotationEditorView.minInlineWidth >= AnnotationEditorView.toolbarMinWidth)
    }
}
