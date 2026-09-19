import AppKit
import os

/// AppDelegate — 截图流程（区域/全屏/窗口/延时）。
///
/// @author ixxxxoooo
extension AppDelegate {

    /// 需要「屏幕录制」权限的入口统一走这里。
    ///
    /// 每次都**现读**，不缓存启动时的快照——用户刚在系统设置里勾完就回来时，
    /// 缓存的旧值会让入口一直说「没权限」。不可用就打开权限引导：
    /// 引导页里既能看到实时状态，也有「重新检测」和「重启 Jietu」两个出口。
    func requireScreenCapturePermission() -> Bool {
        guard !ScreenCapturePermission.isGranted else { return true }
        logger.notice("capture requested without screen recording permission")
        showOnboarding()
        return false
    }

    func handleAreaCapture() {
        overlays.purpose = .screenshot
        guard !overlays.isPresenting else { return }

        guard requireScreenCapturePermission() else { return }

        Task { @MainActor in
            do {
                let snapshots = try await capture.captureAllDisplays()
                // 必须在遮罩窗出现之前枚举窗口，否则会把遮罩自己也算进去。
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                logger.notice(
                    "captured \(snapshots.count) display(s), \(windows.count) window(s) on screen"
                )
                overlays.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: settings.editorMode == .inline
                )
            } catch {
                presentCaptureFailure(error)
            }
        }
    }

    /// 全屏截图：抓鼠标所在显示器，依设置决定进入原地编辑或交付浮窗。
    func handleFullScreenCapture() {
        guard !overlays.isPresenting else { return }
        guard requireScreenCapturePermission() else { return }

        Task { @MainActor in
            do {
                let snapshots = try await capture.captureAllDisplays()
                guard let snapshot = snapshotUnderMouse(snapshots) ?? snapshots.first else {
                    throw CaptureError.noDisplays
                }
                switch settings.editorMode {
                case .inline:
                    if settings.playShutterSound {
                        CaptureOutput.playShutterSound()
                    }
                    copyToClipboard(snapshot.image)
                    openInlineEditor(snapshot.image, allowsCrop: false)
                case .quickAccess:
                    deliver(snapshot.image, onDisplay: snapshot.displayID)
                }
            } catch {
                presentCaptureFailure(error)
            }
        }
    }

    /// 窗口截图：呈现全屏交互遮罩，支持悬停吸附高亮、空格切换自由框选与一键窗口截取。
    func handleWindowCapture() {
        overlays.purpose = .windowCapture
        guard !overlays.isPresenting else { return }
        guard requireScreenCapturePermission() else { return }

        Task { @MainActor in
            do {
                let snapshots = try await capture.captureAllDisplays()
                let windows = WindowHitTester.onScreenWindows(excludingPID: getpid())
                logger.notice(
                    "window capture initiated: \(snapshots.count) display(s), \(windows.count) window(s)"
                )
                overlays.present(
                    session: CaptureSession(snapshots: snapshots, windows: windows),
                    inlineMode: settings.editorMode == .inline
                )
            } catch {
                presentCaptureFailure(error)
            }
        }
    }

    /// 定时截图：延时后走区域截图流程。
    func handleTimedCapture(after seconds: TimeInterval) {
        guard !overlays.isPresenting else { return }
        logger.notice("timed capture scheduled in \(seconds)s")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            handleAreaCapture()
        }
    }

    /// 菜单「取色器」：弹系统放大镜选一个像素，选中直接复制色号（`#RRGGBB`）。
    ///
    /// 取色与复制都在 `ScreenColorPicker` 里（它包的是系统采样器），这里只补一条回执——
    /// 放大镜一收，用户没法确认到底复制到没有。
    func pickColorFromScreen() {
        ScreenColorPicker.shared.pick { [weak self] picked in
            guard let self, let picked else { return }  // nil = 用户按 Esc 取消，什么都不做
            logger.notice("picked color \(picked.hex, privacy: .public)")
            let toast = colorToast ?? ToastPanel()
            colorToast = toast
            toast.present(
                "已复制 \(picked.hex)",
                swatchColor: picked.color,
                near: NSEvent.mouseLocation
            )
        }
    }
}
