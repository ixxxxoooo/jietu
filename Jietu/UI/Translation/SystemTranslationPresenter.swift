import AppKit
import SwiftUI
import Translation

/// 「翻译」这次请求的状态：识别出来的原文 + 系统翻译面板是否弹出。
///
/// @author ixxxxoooo
@MainActor
@Observable
final class TranslationRequest {
    /// 识别出来的原文（图上的字）。
    var text = ""
    /// 系统翻译面板是否弹出。
    var isPresented = false
}

/// 系统翻译面板的宿主视图。
///
/// `translationPresentation` 是 macOS 自己的那个翻译面板（弹窗里能选语言、能朗读、
/// 能替换回原文），只有 SwiftUI 入口——钉图是 AppKit 视图，所以在这里挂一层透明宿主。
///
/// @author ixxxxoooo
private struct TranslationPresentationHost: View {
    @Bindable var request: TranslationRequest

    var body: some View {
        Color.clear
            .translationPresentation(
                isPresented: $request.isPresented,
                text: request.text,
                // 宿主贴在「翻译」按钮上（钉图左下角），面板从按钮下方长出来
                // （与 macOS 自己在截图预览里那颗「翻译」一致；贴到屏幕下缘时系统会自己翻边）。
                arrowEdge: .bottom
            )
    }
}

/// 把 macOS 自己的翻译面板接到 AppKit 视图上。
///
/// 用法：`attach(to:)` 一次，`updateAnchor(_:)` 跟着宿主布局走，`present(text:)` 弹面板。
///
/// @author ixxxxoooo
@MainActor
final class SystemTranslationPresenter {
    private let request = TranslationRequest()
    private var hosting: NSHostingView<TranslationPresentationHost>?

    /// 把宿主挂到某个视图上（面板就从这块地方长出来）。
    func attach(to view: NSView, anchor: NSRect) {
        guard hosting == nil else { return }
        let host = NSHostingView(rootView: TranslationPresentationHost(request: request))
        host.frame = anchor
        host.autoresizingMask = []
        view.addSubview(host)
        hosting = host
    }

    /// 宿主跟着按钮走（钉图窗口会缩放 / 调整大小）。
    func updateAnchor(_ anchor: NSRect) {
        hosting?.frame = anchor
    }

    /// 弹系统翻译面板。`text` 是识别出来的原文，空串时调用方不该走到这儿。
    func present(text: String) {
        request.text = text
        request.isPresented = true
    }

    /// 面板是不是还开着。
    var isPresented: Bool { request.isPresented }

    /// 测试用：交给系统翻译的原文。
    var presentedText: String { request.text }
}
