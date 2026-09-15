import CoreGraphics
import Foundation

/// 一次截图会话：按下热键那一刻冻结下来的所有屏幕，以及当时屏幕上的窗口列表。
///
/// 窗口列表在这里取一次就固定住，因为遮罩窗自己也是窗口，
/// 而且冻结期间用户看到的画面不变，逐帧重新枚举反而会引入不一致。
struct CaptureSession {
    let snapshots: [DisplaySnapshot]
    let windows: [WindowInfo]

    func snapshot(for displayID: CGDirectDisplayID) -> DisplaySnapshot? {
        snapshots.first { $0.displayID == displayID }
    }
}
