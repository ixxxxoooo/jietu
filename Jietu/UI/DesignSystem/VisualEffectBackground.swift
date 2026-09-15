import AppKit
import SwiftUI

/// 把 `NSVisualEffectView` 的毛玻璃带进 SwiftUI。
///
/// 注意 `state = .active`：截图的 HUD 是非激活面板，不强制 active 的话
/// 磨砂层会跟着 App 的激活状态忽明忽暗。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        // 显式锁定深色，不跟随系统外观。
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.appearance = NSAppearance(named: .darkAqua)
    }
}
