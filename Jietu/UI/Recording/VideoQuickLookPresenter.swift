import AppKit
import QuickLookUI

/// 用 **macOS 自带的「快速查看」** 预览成片——按空格弹出来的那个播放器，
/// 底下一整条播放控制（后退 15 秒 / 播放暂停 / 进度 / 音量 / 循环），右上角还有「通过 … 打开」。
///
/// 为什么不用「默认打开方式」也不用预览 App：`.mp4` 的默认程序往往是别的播放器（这台机器上是
/// 哔哩哔哩），而用户要的是系统那个预览——`QLPreviewPanel` 就是系统那份（同一个面板、同一套观感），
/// 又不像 `qlmanage -p` 那样另起一个进程。
///
/// @author ixxxxoooo
@MainActor
final class VideoQuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = VideoQuickLookPresenter()

    /// 面板自己只弱引用 dataSource，所以这里得留一份强引用（单例本身就是）。
    private var url: URL?

    /// 弹面板预览这个文件；再点一次会换成新文件重新加载。
    func present(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else {
            // 拿不到共享面板（极少数环境）：退回默认打开方式，别让这一下点了没反应。
            NSWorkspace.shared.open(url)
            return
        }
        // 我们是后台菜单栏 App：不激活的话面板只是排在本 App 的窗口最前，
        // 别的 App 的窗口照样压在上面（自检里拍到过）。
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// 收掉面板（自检收尾 / 将来要用到）。
    func dismiss() {
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    /// 自检用：面板正开着吗。
    var isVisible: Bool { QLPreviewPanel.shared()?.isVisible ?? false }

    /// 自检用：面板尺寸（塌成一条标题栏的话一眼看得出来）。
    var panelFrame: CGRect { QLPreviewPanel.shared()?.frame ?? .zero }

    /// 自检用：面板里现在有几条预览项。
    var itemCount: Int { url == nil ? 0 : 1 }

    /// 自检用：当前预览项（QL 认不认它）。
    ///
    /// 用 `previewItemURL` 而不是 `previewItemTitle`：后者是 `String!`，
    /// 预览项没准备好时读它会直接崩（自检里踩过一次）。
    var currentItemName: String? {
        QLPreviewPanel.shared()?.currentPreviewItem?.previewItemURL?.lastPathComponent
    }

    // MARK: - QLPreviewPanelDataSource / Delegate

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}
