import AppKit
import SwiftUI
import VisionKit

/// 类 Apple「实况文本」：图片加载后自动识别文字，悬停变文本光标、可直接拖选复制。
///
/// 用 VisionKit 的 `ImageAnalysisOverlayView`，只开文本选择交互，不做按钮触发。
///
/// @author ixxxxoooo
struct LiveTextOverlay: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> ImageAnalysisOverlayView {
        let view = ImageAnalysisOverlayView(context.coordinator)
        view.preferredInteractionTypes = .textSelection
        analyze(image, into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: ImageAnalysisOverlayView, context: Context) {
        if context.coordinator.analyzedImage !== image {
            analyze(image, into: nsView, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func analyze(
        _ image: CGImage,
        into view: ImageAnalysisOverlayView,
        coordinator: Coordinator
    ) {
        coordinator.analyzedImage = image
        Task { @MainActor in
            guard ImageAnalyzer.isSupported else { return }
            let analyzer = ImageAnalyzer()
            let configuration = ImageAnalyzer.Configuration(.text)
            if let analysis = try? await analyzer.analyze(
                image,
                orientation: .up,
                configuration: configuration
            ) {
                view.analysis = analysis
            }
        }
    }

    /// 覆盖整张图。
    final class Coordinator: ImageAnalysisOverlayViewDelegate {
        var analyzedImage: CGImage?

        func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
            CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }
}
