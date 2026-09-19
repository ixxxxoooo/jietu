import AppKit
import SwiftUI

/// 可拖拽的 App 卡片：把本 App 的 `.app` 当**文件**拖出去。
///
/// 系统设置那一栏只列「申请过」的 App，自签名 / Debug 构建经常压根不出现（`tccutil
/// reset` 也救不回来），但那一栏是**接受拖入**的——把 `.app` 拖进去就等于手动把它
/// 加进列表并授权。这就是 PermissionFlow 那个库的核心做法。
///
/// 拖拽载荷故意做成贴近 Finder 原生的文件拖拽（多写几种 pasteboard 类型），
/// 否则系统设置不会收。
///
/// @author ixxxxoooo
struct AppBundleDragCard: NSViewRepresentable {
    let url: URL
    /// 拖拽开始 / 结束时回报，宿主据此把面板切成鼠标穿透。
    var onDragStateChange: (Bool) -> Void

    func makeNSView(context: Context) -> AppBundleDragSourceView {
        let view = AppBundleDragSourceView(url: url)
        view.onDragStateChange = onDragStateChange
        return view
    }

    func updateNSView(_ nsView: AppBundleDragSourceView, context: Context) {
        nsView.update(url: url)
        nsView.onDragStateChange = onDragStateChange
    }
}

/// 真正发起拖拽的 AppKit 视图。
///
/// @author ixxxxoooo
final class AppBundleDragSourceView: NSView, NSDraggingSource {
    private var url: URL
    private let hostingView: NSHostingView<AnyView>
    private var mouseDownPoint: NSPoint?
    private var hasBegunDragging = false

    var onDragStateChange: ((Bool) -> Void)?

    init(url: URL) {
        self.url = url
        hostingView = NSHostingView(rootView: AnyView(AppBundleDragCardContent(url: url)))
        super.init(frame: .zero)

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(url: URL) {
        self.url = url
        hostingView.rootView = AnyView(AppBundleDragCardContent(url: url))
        invalidateIntrinsicContentSize()
    }

    /// 整个卡片都是拖拽热区（内部 SwiftUI 关掉了命中测试）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(56, hostingView.fittingSize.height))
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        hasBegunDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasBegunDragging, let mouseDownPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        // 有个几像素的启动阈值，避免点一下就开始拖。
        guard hypot(current.x - mouseDownPoint.x, current.y - mouseDownPoint.y) > 4 else { return }
        hasBegunDragging = true
        beginAppDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        hasBegunDragging = false
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragStateChange?(true)
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        onDragStateChange?(false)
        mouseDownPoint = nil
        hasBegunDragging = false
    }

    private func beginAppDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: AppBundlePasteboardWriter(url: url))
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 56, height: 56)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56),
            contents: icon
        )

        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }
}

/// 拖拽载荷：把 `.app` 描述成一个 Finder 风格的文件 URL。
///
/// @author ixxxxoooo
private final class AppBundlePasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            .string,
        ]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL, NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"):
            return url.absoluteString
        case NSPasteboard.PasteboardType("NSFilenamesPboardType"):
            return [url.path]
        case .string:
            return url.path
        default:
            return nil
        }
    }
}

/// 卡片外观：App 图标 + 名字 + 拖拽提示。
///
/// @author ixxxxoooo
private struct AppBundleDragCardContent: View {
    let url: URL

    private var name: String {
        FileManager.default.displayName(atPath: url.path)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

            Text(name)
                .font(Theme.Typography.bar)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.md)

            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 13, weight: .regular))
                Text(L10n.dragCardHint)
                    .font(Theme.Typography.compactKeyCap)
            }
            .foregroundStyle(Theme.Colors.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: 56)
        // 玻璃面板里的一个「槽」：只压一层 ramp 的 controlSurface，不描边、不加灰。
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Colors.controlSurface)
        )
        // 事件全部交给外层 AppKit 视图去起拖拽。
        .allowsHitTesting(false)
    }
}
