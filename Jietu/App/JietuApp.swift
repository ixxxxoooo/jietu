import SwiftUI

@main
struct JietuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 目前是纯菜单栏应用（LSUIElement），UI 全部由 AppDelegate 驱动。
        // P4 会把这里替换成真正的设置窗口。
        Settings {
            EmptyView()
        }
    }
}
