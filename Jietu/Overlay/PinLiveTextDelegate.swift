import AppKit
import VisionKit

final class PinLiveTextDelegate: NSObject, ImageAnalysisOverlayViewDelegate {
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}
