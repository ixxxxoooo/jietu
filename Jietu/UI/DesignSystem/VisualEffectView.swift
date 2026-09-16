import AppKit
import SwiftUI

/// 原生 vibrancy 背景；macOS 26 上这些材质由系统用 Liquid Glass 渲染。
///
/// 注意 `state = .active`：截图的 HUD 是非激活面板，不强制 active 的话
/// 磨砂层会跟着 App 的激活状态忽明忽暗。
///
/// 外观**不锁定**，跟随窗口；表面的明暗由 `Theme.Colors.panelScrim` 决定。
///
/// @author ixxxxoooo
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
