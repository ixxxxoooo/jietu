import Carbon.HIToolbox
import Testing
@testable import Jietu

/// 设置面板与数据模型一致性的快照测试。
///
/// @author ygw
@Suite("设置面板一致性")
struct SettingsPanesConsistencyTests {

    // MARK: - HotkeyAction 与 displayString 一致

    @Test("HotkeyAction.title 与实际菜单项标题对齐")
    func actionTitlesMatchMenuItems() {
        let expected: [HotkeyAction: String] = [
            .areaCapture: "区域截图",
            .windowCapture: "窗口截图",
            .fullScreenCapture: "全屏截图",
            .timedCapture: "定时截图",
            .scrollingCapture: "滚动长图",
            .screenRecording: "区域录制",
            .windowRecording: "窗口录制",
            .fullScreenRecording: "全屏录制",
        ]
        for action in HotkeyAction.allCases {
            #expect(action.title == expected[action], "\(action) 的 title 应为 \(expected[action] ?? "?")")
        }
    }

    @Test("Hotkey.displayString 格式为修饰键符号 + 按键名")
    func displayStringFormat() {
        let hotkey = Hotkey(
            keyCode: UInt32(kVK_ANSI_S),
            carbonModifiers: UInt32(cmdKey)
        )
        #expect(hotkey.displayString == "⌘S")
        #expect(hotkey.modifierSymbols == "⌘")
        #expect(hotkey.keySymbol == "S")
    }

    // MARK: - SaveFormat

    @Test("SaveFormat 每个值都有文件扩展名")
    func saveFormatExtensions() {
        #expect(SaveFormat.png.fileExtension == "png")
        #expect(SaveFormat.jpeg.fileExtension == "jpg")
    }

    // MARK: - EditorMode

    @Test("EditorMode 有 inline 和 quickAccess 两种")
    func editorModeValues() {
        #expect(EditorMode(rawValue: "inline") == .inline)
        #expect(EditorMode(rawValue: "quickAccess") == .quickAccess)
        // 无效值返回 nil
        #expect(EditorMode(rawValue: "invalid") == nil)
    }

    @Test("EditorMode 解析持久化值时兼容旧值 window")
    func editorModeLegacyStoredValue() {
        // 旧值 `window`（语义：独立窗口编辑器 → 已并入浮窗预览）应解析为 quickAccess
        #expect(EditorMode(storedValue: "window") == .quickAccess)
        #expect(EditorMode(storedValue: "quickAccess") == .quickAccess)
        #expect(EditorMode(storedValue: "inline") == .inline)
        // 缺失或无效一律回退默认 inline
        #expect(EditorMode(storedValue: nil) == .inline)
        #expect(EditorMode(storedValue: "invalid") == .inline)
    }

    // MARK: - QuickAccessPosition

    @Test("QuickAccessPosition 有左下和右下两个位置")
    func quickAccessPositionValues() {
        let all: [QuickAccessPosition] = [.bottomLeft, .bottomRight]
        #expect(QuickAccessPosition.allCases.count == all.count)
        for pos in all {
            #expect(QuickAccessPosition(rawValue: pos.rawValue) == pos, "\(pos) 的 rawValue 往返应一致")
        }
    }

    // MARK: - AnnotationDefaults

    @Test("AnnotationDefaults.standard 的值符合预期")
    func annotationDefaultsStandard() {
        let d = AnnotationDefaults.standard
        #expect(d.lineWidth > 0, "默认线宽应大于 0")
        #expect(d.fontSize > 0, "默认字号应大于 0")
    }

    // MARK: - SettingsStore 默认值

    @Test("全新的 SettingsStore 使用合理的默认值")
    func freshSettingsStoreDefaults() {
        let (defaults, _) = TestUserDefaults.make()
        let store = SettingsStore(defaults: defaults)

        #expect(store.copyToClipboard == true, "默认应复制到剪贴板")
        #expect(store.playShutterSound == true, "默认应播放快门音")
        #expect(store.saveToDisk == false, "默认不自动保存到磁盘")
        #expect(store.showSaveNotification == true, "默认应显示保存通知")
        #expect(store.saveFormat == SaveFormat.png, "默认格式应为 PNG")
        #expect(store.jpegQuality == 0.9, "默认 JPEG 质量应为 0.9")
        #expect(store.editorMode == EditorMode.inline, "默认编辑模式应为原地编辑")
        #expect(store.quickAccessPosition == QuickAccessPosition.bottomLeft, "默认 Quick Access 位置应为左下角")
        #expect(store.hotkeys.isEmpty, "默认不设任何全局热键")
        #expect(store.recordSystemAudio == false, "默认不录系统音频")
        #expect(store.recordFrameRate == 30, "默认录屏帧率应为 30")
        #expect(store.windowShadowEnabled == false, "默认不加窗口阴影")
    }
}
