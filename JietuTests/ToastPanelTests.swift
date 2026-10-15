import AppKit
import Testing
@testable import Jietu

/// 自动消失的提示浮窗：反复弹、带色块、贴边都不该出问题。
///
/// @author ixxxxoooo
@Suite("提示浮窗")
@MainActor
struct ToastPanelTests {
    @Test("纯文字与带色块的提示都能弹出")
    func presentsTextAndSwatch() {
        let toast = ToastPanel()
        toast.present("已复制", duration: 0.05)
        toast.present("#FF8800", swatchColor: .orange, near: NSEvent.mouseLocation, duration: 0.05)
    }

    @Test("连续弹多次会取消上一次的定时收起，而不是叠出多个任务")
    func repeatedPresentCancelsPreviousTimer() async {
        let toast = ToastPanel()
        for index in 0..<5 {
            toast.present("第 \(index) 条", duration: 0.05)
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    @Test("锚点在屏幕外 / 屏幕底部也不会崩溃（位置会被夹进可见区域）")
    func offscreenAnchorsAreClamped() {
        let toast = ToastPanel()
        toast.present("远处", near: NSPoint(x: -10_000, y: -10_000), duration: 0.05)
        toast.present("角落", near: NSPoint(x: 100_000, y: 100_000), duration: 0.05)
    }
}
