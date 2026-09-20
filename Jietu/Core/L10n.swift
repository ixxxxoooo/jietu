import CoreFoundation
import Foundation

/// 全局本地化字符串访问器。
///
/// 所有用户可见的文案统一走这里，源码中不再出现硬编码的中文 / 英文。
/// 系统语言为中文时返回中文，其余返回英文（由 `Localizable.strings` 驱动）。
///
/// @author ixxxxoooo
enum L10n {

    // MARK: - 菜单栏

    static var menuAreaCapture: String { s("menu.area_capture") }
    static var menuWindowCapture: String { s("menu.window_capture") }
    static var menuFullScreenCapture: String { s("menu.fullscreen_capture") }
    static var menuTimedCapture: String { s("menu.timed_capture") }
    static var menuScrollingCapture: String { s("menu.scrolling_capture") }
    static var menuColorPicker: String { s("menu.color_picker") }
    static var menuRegionRecording: String { s("menu.region_recording") }
    static var menuWindowRecording: String { s("menu.window_recording") }
    static var menuFullScreenRecording: String { s("menu.fullscreen_recording") }
    static var menuRecentHistory: String { s("menu.recent_history") }
    static var menuOpenSaveFolder: String { s("menu.open_save_folder") }
    static var menuNoRecentHistory: String { s("menu.no_recent_history") }
    static var menuPreferences: String { s("menu.preferences") }
    static var menuRestartJietu: String { s("menu.restart_jietu") }
    static var menuQuitJietu: String { s("menu.quit_jietu") }
    static var menuPermissionGuide: String { s("menu.permission_guide") }
    static var menuDragAuthorizeScreenRecording: String { s("menu.drag_authorize_screen_recording") }
    static var menuDragAuthorizeAccessibility: String { s("menu.drag_authorize_accessibility") }
    static func menuSecondsLater(_ n: Int) -> String { sf("menu.seconds_later", n) }
    static func menuScreenRecordingPermission(granted: Bool) -> String {
        granted ? s("menu.screen_recording_granted") : s("menu.screen_recording_not_granted")
    }
    static func menuAccessibilityPermission(granted: Bool) -> String {
        granted ? s("menu.accessibility_granted") : s("menu.accessibility_not_granted")
    }

    // MARK: - 设置页分类

    static var settingsGeneral: String { s("settings.general") }
    static var settingsCapture: String { s("settings.capture") }
    static var settingsHotkeys: String { s("settings.hotkeys") }
    static var settingsQuickAccess: String { s("settings.quick_access") }
    static var settingsRecording: String { s("settings.recording") }
    static var settingsAnnotation: String { s("settings.annotation") }
    static var settingsPermission: String { s("settings.permission") }
    static var settingsAbout: String { s("settings.about") }

    // MARK: - 通用设置

    static var generalLaunchAtLogin: String { s("general.launch_at_login") }
    static var generalLaunchAtLoginDesc: String { s("general.launch_at_login_desc") }
    static var generalPlayShutterSound: String { s("general.play_shutter_sound") }
    static var generalPlayShutterSoundDesc: String { s("general.play_shutter_sound_desc") }
    static var generalCopyToClipboard: String { s("general.copy_to_clipboard") }
    static var generalCopyToClipboardDesc: String { s("general.copy_to_clipboard_desc") }
    static var generalShowNotification: String { s("general.show_notification") }
    static var generalShowNotificationDesc: String { s("general.show_notification_desc") }
    static var generalNotificationDenied: String { s("general.notification_denied") }
    static var generalNotificationDeniedDesc: String { s("general.notification_denied_desc") }
    static var generalOpenNotificationSettings: String { s("general.open_notification_settings") }
    static var generalSectionGeneral: String { s("general.section_general") }
    static var generalDefaultBehaviorFooter: String { s("general.default_behavior_footer") }
    static var generalTheme: String { s("general.theme") }
    static var generalThemeDesc: String { s("general.theme_desc") }
    static var generalSectionAppearance: String { s("general.section_appearance") }

    // MARK: - 外观

    static var appearanceSystem: String { s("appearance.system") }
    static var appearanceLight: String { s("appearance.light") }
    static var appearanceDark: String { s("appearance.dark") }

    // MARK: - 语言

    static var languageSystem: String { s("language.system") }
    static var languageChinese: String { s("language.chinese") }
    static var languageEnglish: String { s("language.english") }
    static var generalLanguage: String { s("general.language") }
    static var generalLanguageDesc: String { s("general.language_desc") }
    static var languageRestartTitle: String { s("language.restart_title") }
    static var languageRestartBody: String { s("language.restart_body") }
    static var languageRestartNow: String { s("language.restart_now") }
    static var languageRestartLater: String { s("language.restart_later") }

    // MARK: - 截图设置

    static var captureSaveToDisk: String { s("capture.save_to_disk") }
    static var captureSaveToDiskDesc: String { s("capture.save_to_disk_desc") }
    static var captureSaveLocation: String { s("capture.save_location") }
    static var captureChoose: String { s("capture.choose") }
    static var captureRevealInFinder: String { s("capture.reveal_in_finder") }
    static var captureSectionOutput: String { s("capture.section_output") }
    static var captureSaveFormat: String { s("capture.save_format") }
    static var captureSaveFormatDesc: String { s("capture.save_format_desc") }
    static var captureJpegQuality: String { s("capture.jpeg_quality") }
    static var captureJpegQualityDesc: String { s("capture.jpeg_quality_desc") }
    static var captureSectionFormat: String { s("capture.section_format") }
    static var captureFilenameTemplate: String { s("capture.filename_template") }
    static var captureResetDefault: String { s("capture.reset_default") }
    static var captureSectionNaming: String { s("capture.section_naming") }
    static var captureWindowShadow: String { s("capture.window_shadow") }
    static var captureWindowShadowDesc: String { s("capture.window_shadow_desc") }
    static var captureShadowSize: String { s("capture.shadow_size") }
    static var captureShadowSizeDesc: String { s("capture.shadow_size_desc") }
    static var captureSectionWindowCapture: String { s("capture.section_window_capture") }
    static func captureFilenameHint(_ hint: String, _ preview: String) -> String {
        sf("capture.filename_hint", hint, preview)
    }

    // MARK: - 快捷键设置

    static var hotkeysSectionGlobal: String { s("hotkeys.section_global") }
    static var hotkeysSectionGlobalFooter: String { s("hotkeys.section_global_footer") }
    static var hotkeysSectionEditor: String { s("hotkeys.section_editor") }
    static var hotkeysSectionEditorFooter: String { s("hotkeys.section_editor_footer") }
    static var hotkeysResetDefault: String { s("hotkeys.reset_default") }

    // MARK: - 快捷键动作

    static var actionAreaCapture: String { s("action.area_capture") }
    static var actionWindowCapture: String { s("action.window_capture") }
    static var actionFullScreenCapture: String { s("action.fullscreen_capture") }
    static var actionTimedCapture: String { s("action.timed_capture") }
    static var actionScrollingCapture: String { s("action.scrolling_capture") }
    static var actionRegionRecording: String { s("action.region_recording") }
    static var actionWindowRecording: String { s("action.window_recording") }
    static var actionFullScreenRecording: String { s("action.fullscreen_recording") }

    static var actionAreaCaptureDesc: String { s("action.area_capture_desc") }
    static var actionWindowCaptureDesc: String { s("action.window_capture_desc") }
    static var actionFullScreenCaptureDesc: String { s("action.fullscreen_capture_desc") }
    static func actionTimedCaptureDesc(_ seconds: Int) -> String { sf("action.timed_capture_desc", seconds) }
    static var actionScrollingCaptureDesc: String { s("action.scrolling_capture_desc") }
    static var actionRegionRecordingDesc: String { s("action.region_recording_desc") }
    static var actionWindowRecordingDesc: String { s("action.window_recording_desc") }
    static var actionFullScreenRecordingDesc: String { s("action.fullscreen_recording_desc") }

    // MARK: - 编辑器快捷键

    static var editorUndo: String { s("editor.undo") }
    static var editorRedo: String { s("editor.redo") }
    static var editorUndoDesc: String { s("editor.undo_desc") }
    static var editorRedoDesc: String { s("editor.redo_desc") }

    // MARK: - 浮窗设置

    static var quickAccessDockPosition: String { s("quick_access.dock_position") }
    static var quickAccessDockPositionDesc: String { s("quick_access.dock_position_desc") }
    static var quickAccessAutoClose: String { s("quick_access.auto_close") }
    static var quickAccessAutoCloseDesc: String { s("quick_access.auto_close_desc") }
    static var quickAccessSectionTitle: String { s("quick_access.section_title") }
    static var quickAccessBottomRight: String { s("quick_access.bottom_right") }
    static var quickAccessBottomLeft: String { s("quick_access.bottom_left") }
    static func quickAccessSeconds(_ n: Int) -> String { sf("quick_access.seconds", n) }
    static var quickAccessNever: String { s("quick_access.never") }

    // MARK: - 录屏设置

    static var recordingSystemAudio: String { s("recording.system_audio") }
    static var recordingSystemAudioDesc: String { s("recording.system_audio_desc") }
    static var recordingMicrophone: String { s("recording.microphone") }
    static var recordingMicrophoneDesc: String { s("recording.microphone_desc") }
    static var recordingFrameRate: String { s("recording.frame_rate") }
    static var recordingFrameRateDesc: String { s("recording.frame_rate_desc") }
    static var recordingSectionRecording: String { s("recording.section_recording") }
    static var recordingSaveLocation: String { s("recording.save_location") }
    static var recordingSectionOutput: String { s("recording.section_output") }
    static var recordingOutputFooter: String { s("recording.output_footer") }

    // MARK: - 标注设置

    static var annotationEditorMode: String { s("annotation.editor_mode") }
    static var annotationEditorModeDesc: String { s("annotation.editor_mode_desc") }
    static var annotationSectionAnnotation: String { s("annotation.section_annotation") }
    static var annotationDefaultStyle: String { s("annotation.default_style") }
    static var annotationSectionDefaultStyle: String { s("annotation.section_default_style") }
    static var annotationDefaultStyleFooter: String { s("annotation.default_style_footer") }
    static var annotationEditorModeInline: String { s("annotation.editor_mode_inline") }
    static var annotationEditorModeQuickAccess: String { s("annotation.editor_mode_quick_access") }

    // MARK: - 标注工具

    static var toolSelect: String { s("tool.select") }
    static var toolRectangle: String { s("tool.rectangle") }
    static var toolEllipse: String { s("tool.ellipse") }
    static var toolArrow: String { s("tool.arrow") }
    static var toolLine: String { s("tool.line") }
    static var toolPen: String { s("tool.pen") }
    static var toolHighlight: String { s("tool.highlight") }
    static var toolSpotlight: String { s("tool.spotlight") }
    static var toolPixelate: String { s("tool.pixelate") }
    static var toolBlur: String { s("tool.blur") }
    static var toolText: String { s("tool.text") }
    static var toolCounter: String { s("tool.counter") }
    static var toolEraser: String { s("tool.eraser") }
    static var toolCrop: String { s("tool.crop") }

    // MARK: - 标注样式

    static var styleStroke: String { s("style.stroke") }
    static var styleCallout: String { s("style.callout") }
    static var styleMosaicGranularity: String { s("style.mosaic_granularity") }
    static var styleBlurRadius: String { s("style.blur_radius") }
    static var styleEraserSize: String { s("style.eraser_size") }

    // MARK: - 标注颜色名称

    static var colorRed: String { s("color.red") }
    static var colorOrange: String { s("color.orange") }
    static var colorYellow: String { s("color.yellow") }
    static var colorGreen: String { s("color.green") }
    static var colorBlue: String { s("color.blue") }
    static var colorWhite: String { s("color.white") }
    static var colorBlack: String { s("color.black") }
    static var colorCustom: String { s("color.custom") }

    // MARK: - 工具栏

    static var toolbarSave: String { s("toolbar.save") }
    static var toolbarSaveHelp: String { s("toolbar.save_help") }
    static var toolbarPin: String { s("toolbar.pin") }
    static var toolbarCancel: String { s("toolbar.cancel") }
    static var toolbarConfirm: String { s("toolbar.confirm") }
    static var toolbarOCR: String { s("toolbar.ocr") }
    static var toolbarScrollCapture: String { s("toolbar.scroll_capture") }
    static var toolbarRecord: String { s("toolbar.record") }

    // MARK: - 滚动截图选项

    static var scrollWhoScrolls: String { s("scroll.who_scrolls") }
    static var scrollManual: String { s("scroll.manual") }
    static var scrollAutomatic: String { s("scroll.automatic") }
    static var scrollManualHelp: String { s("scroll.manual_help") }
    static var scrollAutomaticHelp: String { s("scroll.automatic_help") }

    // MARK: - 裁剪

    static var cropDragHint: String { s("crop.drag_hint") }
    static var cropFinish: String { s("crop.finish") }
    static var cropFinishHelp: String { s("crop.finish_help") }
    static var cropCancelHelp: String { s("crop.cancel_help") }

    // MARK: - 权限设置

    static var permScreenRecording: String { s("perm.screen_recording") }
    static var permScreenRecordingGranted: String { s("perm.screen_recording_granted") }
    static var permScreenRecordingNeedsRelaunch: String { s("perm.screen_recording_needs_relaunch") }
    static var permScreenRecordingDenied: String { s("perm.screen_recording_denied") }
    static var permRecheck: String { s("perm.recheck") }
    static var permRecheckHelp: String { s("perm.recheck_help") }
    /// 「重新检测」读的是**本进程**启动时拿到的授权：勾选与撤销都要重启才反映出来。
    static var permRecheckStaleHint: String { s("perm.recheck_stale_hint") }
    static var permGrantTarget: String { s("perm.grant_target") }
    static var permGrantTargetDesc: String { s("perm.grant_target_desc") }
    static var permGrantAction: String { s("perm.grant_action") }
    static var permDragAuthorize: String { s("perm.drag_authorize") }
    static var permDragAuthorizeHelp: String { s("perm.drag_authorize_help") }
    static var permNeedsRelaunch: String { s("perm.needs_relaunch") }
    static var permNeedsRelaunchDesc: String { s("perm.needs_relaunch_desc") }
    static var permRestartJietu: String { s("perm.restart_jietu") }
    static var permAccessibility: String { s("perm.accessibility") }
    static var permAccessibilityGranted: String { s("perm.accessibility_granted") }
    static var permAccessibilityDenied: String { s("perm.accessibility_denied") }
    static var permSectionScreenRecording: String { s("perm.section_screen_recording") }
    static var permSectionAccessibility: String { s("perm.section_accessibility") }
    static var permAccessibilityFooter: String { s("perm.accessibility_footer") }
    static var permGranted: String { s("perm.granted") }
    static var permNotGranted: String { s("perm.not_granted") }

    // MARK: - 关于页

    static func aboutVersion(_ short: String, _ build: String) -> String { sf("about.version", short, build) }
    static var aboutBuildChannel: String { s("about.build_channel") }
    static var aboutSectionInfo: String { s("about.section_info") }
    static var aboutSectionLinks: String { s("about.section_links") }
    static var aboutTagline: String { s("about.tagline") }
    static var aboutCopyright: String { s("about.copyright") }
    static var aboutIssues: String { s("about.issues") }

    // MARK: - 引导页

    static func onboardingWelcome(_ name: String) -> String { sf("onboarding.welcome", name) }
    static var onboardingScreenRecordingPerm: String { s("onboarding.screen_recording_perm") }
    static var onboardingSetHotkey: String { s("onboarding.set_hotkey") }
    static var onboardingAllReady: String { s("onboarding.all_ready") }
    static var onboardingWelcomeSubtitle: String { s("onboarding.welcome_subtitle") }
    static var onboardingPermGrantedSubtitle: String { s("onboarding.perm_granted_subtitle") }
    static var onboardingPermNeedsRelaunchSubtitle: String { s("onboarding.perm_needs_relaunch_subtitle") }
    static var onboardingPermDeniedSubtitle: String { s("onboarding.perm_denied_subtitle") }
    static var onboardingHotkeySubtitle: String { s("onboarding.hotkey_subtitle") }
    static func onboardingReadyWithHotkey(_ key: String) -> String { sf("onboarding.ready_with_hotkey", key) }
    static var onboardingReadyFromMenu: String { s("onboarding.ready_from_menu") }
    static var onboardingCopyToClipboard: String { s("onboarding.copy_to_clipboard") }
    static var onboardingCopyToClipboardDesc: String { s("onboarding.copy_to_clipboard_desc") }
    static var onboardingLaunchAtLogin: String { s("onboarding.launch_at_login") }
    static var onboardingLaunchAtLoginDesc: String { s("onboarding.launch_at_login_desc") }
    static var onboardingChangeInSettings: String { s("onboarding.change_in_settings") }
    static var onboardingScreenRecording: String { s("onboarding.screen_recording") }
    static var onboardingAccessibility: String { s("onboarding.accessibility") }
    static var onboardingAccessibilityGranted: String { s("onboarding.accessibility_granted") }
    static var onboardingAccessibilityDenied: String { s("onboarding.accessibility_denied") }
    static var onboardingGrantTarget: String { s("onboarding.grant_target") }
    static var onboardingGrantTargetDesc: String { s("onboarding.grant_target_desc") }
    static var onboardingRelaunchNeeded: String { s("onboarding.relaunch_needed") }
    static var onboardingRelaunchDesc: String { s("onboarding.relaunch_desc") }
    static var onboardingRelaunchHint: String { s("onboarding.relaunch_hint") }
    static var onboardingDragHint: String { s("onboarding.drag_hint") }
    static var onboardingAuthorizeAccessibility: String { s("onboarding.authorize_accessibility") }
    static var onboardingNoHotkeyHint: String { s("onboarding.no_hotkey_hint") }
    static var onboardingFromMenuBar: String { s("onboarding.from_menu_bar") }
    static var onboardingFromMenuBarDesc: String { s("onboarding.from_menu_bar_desc") }
    static var onboardingMoreInSettings: String { s("onboarding.more_in_settings") }
    static var onboardingMoreInSettingsDesc: String { s("onboarding.more_in_settings_desc") }
    static var onboardingSettingsHint: String { s("onboarding.settings_hint") }

    // MARK: - 引导页按钮

    static var onboardingContinue: String { s("onboarding.continue") }
    static var onboardingLater: String { s("onboarding.later") }
    static var onboardingAuthorize: String { s("onboarding.authorize") }
    static var onboardingStart: String { s("onboarding.start") }
    static var onboardingPrevious: String { s("onboarding.previous") }

    // MARK: - 录制控制条

    static var recordReady: String { s("record.ready") }
    static var recordStart: String { s("record.start") }
    static var recordPause: String { s("record.pause") }
    static var recordResume: String { s("record.resume") }
    static var recordStop: String { s("record.stop") }
    static var recordCancelNoSave: String { s("record.cancel_no_save") }
    static var recordSystemAudioOn: String { s("record.system_audio_on") }
    static var recordSystemAudioOff: String { s("record.system_audio_off") }
    static var recordMicOff: String { s("record.mic_off") }
    static var recordMicOffReady: String { s("record.mic_off_ready") }
    static var recordMicActive: String { s("record.mic_active") }
    static var recordMicUnavailable: String { s("record.mic_unavailable") }
    static var recordMicNotRecorded: String { s("record.mic_not_recorded") }
    static var recordDefaultMic: String { s("record.default_mic") }
    static var recordSelectMicMenu: String { s("record.select_mic_menu") }

    // MARK: - Quick Access 浮窗动作

    static var qaClose: String { s("qa.close") }
    static var qaPin: String { s("qa.pin") }
    static var qaAnnotate: String { s("qa.annotate") }
    static var qaCopy: String { s("qa.copy") }
    static var qaSave: String { s("qa.save") }
    static var qaPlay: String { s("qa.play") }
    static var qaRevealInFinder: String { s("qa.reveal_in_finder") }
    static var qaCopyFile: String { s("qa.copy_file") }
    static var qaTrimVideo: String { s("qa.trim_video") }
    static var qaSaveAs: String { s("qa.save_as") }
    static var qaPlayWithPreview: String { s("qa.play_with_preview") }
    static var qaTrimEllipsis: String { s("qa.trim_ellipsis") }
    static var qaExportGif: String { s("qa.export_gif") }
    static var qaVideoHelp: String { s("qa.video_help") }
    static var qaImageHelp: String { s("qa.image_help") }

    // MARK: - 钉图

    static var pinCopyImage: String { s("pin.copy_image") }
    static var pinActualSize: String { s("pin.actual_size") }
    static var pinEdit: String { s("pin.edit") }
    static var pinLiveTextOn: String { s("pin.live_text_on") }
    static var pinLiveTextOff: String { s("pin.live_text_off") }
    static var pinTranslate: String { s("pin.translate") }
    static var pinClose: String { s("pin.close") }
    static var pinEditTooltip: String { s("pin.edit_tooltip") }
    static var pinCloseTooltip: String { s("pin.close_tooltip") }
    static var pinLiveTextTooltip: String { s("pin.live_text_tooltip") }
    static var pinTranslateTooltip: String { s("pin.translate_tooltip") }
    static var pinExitLiveText: String { s("pin.exit_live_text") }
    static var pinRecognizing: String { s("pin.recognizing") }
    static var pinNoTextFound: String { s("pin.no_text_found") }
    static var pinNoTextFoundDetail: String { s("pin.no_text_found_detail") }

    // MARK: - 放大镜信息

    static var loupeCoordinate: String { s("loupe.coordinate") }
    static var loupeRegion: String { s("loupe.region") }

    // MARK: - 取色器

    static var colorPickerHint: String { s("color_picker.hint") }

    // MARK: - 遮罩层提示

    static func overlayDisplayInfo(_ display: Int, _ total: Int, _ w: Double, _ h: Double, _ scale: Double) -> String {
        sf("overlay.display_info", display, total, w, h, scale)
    }
    static var overlayClickWindowRecord: String { s("overlay.click_window_record") }
    static var overlayDragAreaRecord: String { s("overlay.drag_area_record") }
    static var overlayScrollDragHint: String { s("overlay.scroll_drag_hint") }
    static var overlayScrollAdjustHint: String { s("overlay.scroll_adjust_hint") }
    static var overlayClickWindowCapture: String { s("overlay.click_window_capture") }
    static var overlayDragCapture: String { s("overlay.drag_capture") }
    static var overlaySelectionConfirm: String { s("overlay.selection_confirm") }
    static var overlaySwitchFreeSelect: String { s("overlay.switch_free_select") }
    static var overlaySwitchWindowMode: String { s("overlay.switch_window_mode") }
    static var overlayEscCancel: String { s("overlay.esc_cancel") }

    // MARK: - CaptureError

    static var errorPermissionDenied: String { s("error.permission_denied") }
    static func errorNoShareableContent(_ detail: String) -> String { sf("error.no_shareable_content", detail) }
    static var errorNoDisplays: String { s("error.no_displays") }
    static func errorDisplayNotShareable(_ id: UInt32) -> String { sf("error.display_not_shareable", id) }
    static func errorEmptyImage(_ id: UInt32) -> String { sf("error.empty_image", id) }
    static var errorEmptyRegion: String { s("error.empty_region") }
    static func errorWindowNotCapturable(_ id: UInt32) -> String { sf("error.window_not_capturable", id) }
    static var errorNoWindowUnderCursor: String { s("error.no_window_under_cursor") }

    static var errorRecoveryPermission: String { s("error.recovery_permission") }
    static var errorRecoveryRelaunch: String { s("error.recovery_relaunch") }
    static var errorRecoveryNoDisplays: String { s("error.recovery_no_displays") }
    static var errorRecoveryEmptyRegion: String { s("error.recovery_empty_region") }
    static var errorRecoveryNoWindow: String { s("error.recovery_no_window") }

    // MARK: - 通知

    static var notifySaved: String { s("notify.saved") }
    static var notifyRecordingComplete: String { s("notify.recording_complete") }
    static func notifyDuration(_ min: Int, _ sec: Int) -> String { sf("notify.duration", min, sec) }
    static var notifyMicUnavailable: String { s("notify.mic_unavailable") }
    static var notifyMicUnavailableBody: String { s("notify.mic_unavailable_body") }

    // MARK: - Alert

    static var alertOK: String { s("alert.ok") }
    static var alertCaptureFailed: String { s("alert.capture_failed") }
    static var alertRecordingFailed: String { s("alert.recording_failed") }
    static var alertOpenSystemSettings: String { s("alert.open_system_settings") }
    static func alertHotkeyFailed(_ action: String, _ key: String) -> String { sf("alert.hotkey_failed", action, key) }
    static var alertHotkeyConflict: String { s("alert.hotkey_conflict") }

    // MARK: - 复制色值

    static func copiedColor(_ hex: String) -> String { sf("copied_color", hex) }

    // MARK: - 标注样式摘要

    static func annotationStyleSummary(_ tool: String, _ color: String, _ width: Int, _ fontSize: Int) -> String {
        sf("annotation.style_summary", tool, color, width, fontSize)
    }

    // MARK: - Info.plist 权限

    static var infoPlistMicrophoneUsage: String { s("info.microphone_usage") }
    static var infoPlistScreenCaptureUsage: String { s("info.screen_capture_usage") }

    // MARK: - 滚动截图面板

    static var scrollPanelTitle: String { s("scroll_panel.title") }
    static var scrollPanelManual: String { s("scroll_panel.manual") }
    static var scrollPanelManualHelp: String { s("scroll_panel.manual_help") }
    static var scrollPanelAutomatic: String { s("scroll_panel.automatic") }
    static var scrollPanelAutomaticHelp: String { s("scroll_panel.automatic_help") }
    static var scrollPanelCancel: String { s("scroll_panel.cancel") }
    static var scrollPanelFinish: String { s("scroll_panel.finish") }
    static var scrollPanelHelp: String { s("scroll_panel.help") }
    static func scrollPanelStitched(_ px: Int) -> String { sf("scroll_panel.stitched", px) }
    static var scrollPanelReady: String { s("scroll_panel.ready") }
    static var scrollPanelWaiting: String { s("scroll_panel.waiting") }

    // MARK: - 滚动截图 Alert

    static var scrollNeedAccessibility: String { s("scroll.need_accessibility") }
    static var scrollNeedAccessibilityBody: String { s("scroll.need_accessibility_body") }
    static var scrollUseManual: String { s("scroll.use_manual") }
    static var scrollNoContent: String { s("scroll.no_content") }
    static var scrollNoContentBody: String { s("scroll.no_content_body") }

    // MARK: - GIF 导出

    static var gifExporting: String { s("gif.exporting") }
    static func gifExportingProgress(_ percent: Int) -> String { sf("gif.exporting_progress", percent) }
    static var gifExported: String { s("gif.exported") }
    static var gifExportFailed: String { s("gif.export_failed") }

    // MARK: - 快捷键录制器

    static var hotkeyRecorderPlaceholder: String { s("hotkey_recorder.placeholder") }
    static var hotkeyRecorderClear: String { s("hotkey_recorder.clear") }
    static var hotkeyRecorderNotSet: String { s("hotkey_recorder.not_set") }
    static var hotkeyRecorderNeedModifier: String { s("hotkey_recorder.need_modifier") }

    // MARK: - 设置页导航

    static var settingsBack: String { s("settings.back") }
    static var settingsForward: String { s("settings.forward") }

    // MARK: - 引导窗口标题

    static var onboardingWindowTitle: String { s("onboarding.window_title") }

    // MARK: - 历史记录

    static var historyTitle: String { s("history.title") }
    static var historyDone: String { s("history.done") }
    static var historyNoRecords: String { s("history.no_records") }
    static var historyAutoDisplay: String { s("history.auto_display") }
    static var historyOpenFolder: String { s("history.open_folder") }
    static var historyClearAll: String { s("history.clear_all") }
    static var historyCannotRead: String { s("history.cannot_read") }
    static var historyCopied: String { s("history.copied") }
    static var historyCopy: String { s("history.copy") }
    static var historyPin: String { s("history.pin") }
    static var historyReveal: String { s("history.reveal") }
    static var historyEdit: String { s("history.edit") }
    static var historyCopyTooltip: String { s("history.copy_tooltip") }
    static var historyPinTooltip: String { s("history.pin_tooltip") }
    static var historyRevealTooltip: String { s("history.reveal_tooltip") }
    static var historyEditTooltip: String { s("history.edit_tooltip") }
    static var historyToday: String { s("history.today") }
    static var historyYesterday: String { s("history.yesterday") }
    static func historyMonthDay(_ month: Int, _ day: Int) -> String { sf("history.month_day", month, day) }
    static func historyYearMonthDay(_ year: Int, _ month: Int, _ day: Int) -> String { sf("history.year_month_day", year, month, day) }

    // MARK: - 拖拽授权面板

    static var dragCardHint: String { s("drag_card.hint") }
    static func dragPanelInstruction(_ name: String) -> String { sf("drag_panel.instruction", name) }
    static var dragPanelClose: String { s("drag_panel.close") }
    static var dragPanelRestart: String { s("drag_panel.restart") }
    static var dragPanelRestartHelp: String { s("drag_panel.restart_help") }
    /// 列表里已经有一行、却还是未授权时怎么收场（旧签名身份留下的死行）。
    static var dragPanelStaleRow: String { s("drag_panel.stale_row") }

    // MARK: - 权限面板

    static var permPaneScreenRecording: String { s("perm_pane.screen_recording") }
    static var permPaneAccessibility: String { s("perm_pane.accessibility") }
    static var permPaneDragHintSR: String { s("perm_pane.drag_hint_sr") }
    static var permPaneDragHintAX: String { s("perm_pane.drag_hint_ax") }

    // MARK: - 箭头样式

    static var arrowTapered: String { s("arrow.tapered") }
    static var arrowDoubleEnded: String { s("arrow.double_ended") }
    static var arrowLine: String { s("arrow.line") }
    static var arrowDotTail: String { s("arrow.dot_tail") }

    // MARK: - 矩形角样式

    static var cornerSquare: String { s("corner.square") }
    static var cornerRounded: String { s("corner.rounded") }

    // MARK: - 填充模式

    static var fillNone: String { s("fill.none") }
    static var fillOpaque: String { s("fill.opaque") }
    static var fillTranslucent: String { s("fill.translucent") }

    // MARK: - 文字占位

    static var textPlaceholder: String { s("text.placeholder") }

    // MARK: - 文件名模板

    static var filenamePlaceholderHint: String { s("filename.placeholder_hint") }

    // MARK: - GIF 导出错误

    static var gifErrNoVideoTrack: String { s("gif_error.no_video_track") }
    static func gifErrReader(_ reason: String) -> String { sf("gif_error.reader", reason) }
    static var gifErrNoFrames: String { s("gif_error.no_frames") }
    static var gifErrEncodeFailed: String { s("gif_error.encode_failed") }
    static var gifErrCannotAddTrack: String { s("gif_error.cannot_add_track") }
    static var gifErrCannotReadFile: String { s("gif_error.cannot_read_file") }
    static var gifErrDecodingInterrupted: String { s("gif_error.decoding_interrupted") }

    // MARK: - 设置组件

    static func buildChannelHelp(_ bundleId: String) -> String { sf("settings.build_channel_help", bundleId) }

    // MARK: - 滚动截图运行中提示

    static var scrollHintAutoPaused: String { s("scroll_hint.auto_paused") }
    static var scrollHintAutoScrolling: String { s("scroll_hint.auto_scrolling") }
    static var scrollHintManual: String { s("scroll_hint.manual") }

    // MARK: - 菜单栏 Tooltip

    static var menuBarTooltip: String { s("menu_bar.tooltip") }

    // MARK: - CaptureOutput 错误

    static var errorEncodingFailed: String { s("error.encoding_failed") }
    static var errorEmptySelection: String { s("error.empty_selection") }

    // MARK: - RecordingEngine 错误

    static var recErrPermissionDenied: String { s("rec_error.permission_denied") }
    static func recErrDisplayNotShareable(_ id: UInt32) -> String { sf("rec_error.display_not_shareable", id) }
    static var recErrEmptyRegion: String { s("rec_error.empty_region") }
    static func recErrStartFailed(_ reason: String) -> String { sf("rec_error.start_failed", reason) }
    static func recErrStream(_ desc: String) -> String { sf("rec_error.stream", desc) }
    static func recErrWriter(_ desc: String) -> String { sf("rec_error.writer", desc) }
    static var recErrNoFrames: String { s("rec_error.no_frames") }

    // MARK: - MicrophoneRecorder 错误

    static var micErrAudioUnitUnavailable: String { s("mic_error.audio_unit_unavailable") }
    static var micErrInputFormatUnavailable: String { s("mic_error.input_format_unavailable") }
    static var micErrConverterUnavailable: String { s("mic_error.converter_unavailable") }

    // MARK: - RecordingWriter 内部错误

    static var writerErrVideoTrack: String { s("writer_error.video_track") }
    static var writerErrStartWriting: String { s("writer_error.start_writing") }

    // MARK: - 内部辅助

    /// 当前设置里选中的语言（UserDefaults）；无设置则跟随系统。
    ///
    /// `nonisolated`：错误类型等非主线程上下文也要读得到。
    nonisolated private static var preferredLanguageCode: String {
        let raw = UserDefaults.standard.string(forKey: "appearance.language") ?? AppLanguage.system.rawValue
        let language = AppLanguage(rawValue: raw) ?? .system
        return language.resolvedCode
    }

    /// 用指定 `.lproj` 的 CFBundle 读字符串——不依赖 `@MainActor` 的 `Bundle.main`。
    nonisolated static func s(_ key: String) -> String {
        let code = preferredLanguageCode
        if let path = Bundle.main.path(forResource: code, ofType: "lproj") {
            let url = URL(fileURLWithPath: path) as CFURL
            if let cfBundle = CFBundleCreate(nil, url) {
                let cfResult = CFBundleCopyLocalizedString(
                    cfBundle,
                    key as CFString,
                    key as CFString,
                    "Localizable" as CFString
                )
                if let value = cfResult as String?, value != key {
                    return value
                }
                // 某些环境下 CopyLocalizedString 对子 bundle 直接返回 key，改读文件。
                if let direct = loadString(key, fromLprojPath: path) {
                    return direct
                }
            }
        }
        let cfResult = CFBundleCopyLocalizedString(
            CFBundleGetMainBundle(),
            key as CFString,
            key as CFString,
            "Localizable" as CFString
        )
        return cfResult as String? ?? key
    }

    /// 直接从 `Localizable.strings` 解析（CFBundle 对 .lproj 子包偶发失败时的兜底）。
    nonisolated private static func loadString(_ key: String, fromLprojPath path: String) -> String? {
        let stringsURL = URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")
        guard let dict = NSDictionary(contentsOf: stringsURL) as? [String: String] else { return nil }
        return dict[key]
    }

    nonisolated static func sf(_ key: String, _ args: any CVarArg...) -> String {
        String(format: s(key), arguments: args)
    }
}
