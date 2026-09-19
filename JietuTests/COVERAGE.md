# 测试覆盖对照表

> 截至 2026-09-19，326 个 `@Test`，37 个 `@Suite`。
>
> 「selftest」列标注了 `AppDelegate+SelfTest.swift` 中的 DEBUG 自检命令覆盖情况。
> selftest 在真实窗口环境里跑，能覆盖单元测试难以触达的 UI 层。

## App 层

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `AppDelegate.swift` | — | ✅ 全流程自检 |
| `AppDelegate+Capture.swift` | — | ✅ 区域/窗口/全屏截图 |
| `AppDelegate+Recording.swift` | `RecordingTests` | ✅ 录屏流程 |
| `AppDelegate+Scrolling.swift` | — | ✅ 滚动长图流程 |
| `AppDelegate+Delivery.swift` | — | ✅ 落盘/剪贴板/通知 |
| `AppDelegate+SelfTest.swift` | — | （自身即自检） |
| `JietuApp.swift` | — | — |

## Core/Annotation

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `Annotation.swift` | `AnnotationGeometryTests` | — |
| `AnnotationDefaults.swift` | `SettingsPanesConsistencyTests` | — |
| `AnnotationGeometry.swift` | `AnnotationGeometryTests` | — |
| `AnnotationRenderer.swift` | `AnnotationRendererTests` | — |
| `AnnotationRenderer+Arrows.swift` | `AnnotationRendererTests` | — |
| `AnnotationRenderer+BrushText.swift` | `AnnotationRendererTests` | — |
| `AnnotationRenderer+BlockEffects.swift` | `AnnotationRendererTests` | — |
| `AnnotationStyle.swift` | `AnnotationGeometryTests` | — |
| `CropOperation.swift` | `OverlayCanvasCropTests` | — |

## Core/Capture

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `CaptureEngine.swift` | — | ✅ 截图引擎 |
| `CaptureError.swift` | `CaptureErrorTests` | — |
| `DisplayGeometry.swift` | `DisplayGeometryTests` | — |
| `DisplaySnapshot.swift` | `DisplaySnapshotTests` | — |
| `PixelSampler.swift` | `CaptureOutputTests` (间接) | — |
| `WindowEffects.swift` | `WindowEffectsTests` | ✅ 窗口截图 |
| `WindowInfo.swift` | — | ✅ 窗口列表 |

## Core/Diagnostics

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `CaptureSelfTest.swift` | — | （自身即自检） |
| `InteractionMetrics.swift` | — | — |

## Core/History

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `HistoryStore.swift` | `HistoryStoreTests` | — |

## Core/Hotkeys

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `EditorShortcut.swift` | `EditorShortcutTests` | — |
| `Hotkey.swift` | `HotkeyTests` | — |
| `HotkeyAction.swift` | `HotkeyCenterTests` | — |
| `HotkeyCenter.swift` | `HotkeyCenterTests` | — |

## Core/ImageIO

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `CaptureOutput.swift` | `CaptureOutputTests`, `CaptureOutputRetinaTests` | ✅ 保存 |
| `FilenameTemplate.swift` | `FilenameTemplateTests`, `FilenameTemplateBoundaryTests` | — |

## Core/Notifications

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `CaptureNotifier.swift` | — | ✅ 通知 |

## Core/OCR

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `OCRService.swift` | `OCRServiceTests` | — |

## Core/Permissions

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `AccessibilityPermission.swift` | `MenuBarTests` (间接) | ✅ 权限检查 |
| `PermissionPane.swift` | — | — |
| `ScreenCapturePermission.swift` | — | ✅ 权限检查 |
| `SystemSettingsWindow.swift` | — | — |

## Core/Recording

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `AudioInputDevices.swift` | — | — |
| `GifExporter.swift` | `GifExporterTests` | — |
| `MicrophoneCapture.swift` | — | ✅ 录屏（`--selftest-record`） |
| `MicrophoneRecorder.swift` | — | ✅ 录屏 |
| `RecordingEngine.swift` | `RecordingTests` | ✅ 录屏 |
| `RecordingWriter.swift` | — | ✅ 录屏 |
| `VideoEncodingSettings.swift` | `RecordingTests` | — |
| `VideoThumbnail.swift` | — | — |
| `VideoTrimmer.swift` | `VideoTrimmerTests` | — |

## Core/Scrolling

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `AutoScroller.swift` | `AutoScrollTests` | ✅ 自动滚动 |
| `ScrollStitcher.swift` | `ScrollStitcherTests` | — |
| `ScrollStitcherSession.swift` | `ScrollStitcherTests` | — |
| `ScrollingCaptureSession.swift` | `AutoScrollTests` (shouldScroll) | ✅ 滚动长图 |

## Core/Settings

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `AppAppearance.swift` | — | — |
| `LaunchAtLogin.swift` | — | — |
| `SettingsStore.swift` | `SettingsStoreTests`, `SettingsPanesConsistencyTests` | — |
| `SettingsTypes.swift` | `SettingsPanesConsistencyTests` | — |

## Overlay

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `CaptureSession.swift` | — | ✅ 截图流程 |
| `InlineAnnotationToolbar.swift` | `InlineToolbarModelTests` | ✅ 工具栏 |
| `OverlayCanvasView.swift` | `OverlayCanvasCropTests`, `OverlayCanvasZoomTests` | ✅ 遮罩画布 |
| `OverlayCanvasView+Actions.swift` | `OverlayCanvasZoomTests` | ✅ |
| `OverlayCanvasView+InlineAnnotation.swift` | `InlineToolbarModelTests` | ✅ |
| `OverlayCanvasView+Loupe.swift` | — | ✅ 放大镜 |
| `OverlayCanvasView+Rendering.swift` | — | ✅ |
| `OverlayCanvasView+Selection.swift` | `SelectionGeometryTests` (间接) | ✅ 选区 |
| `OverlayCanvasView+Zoom.swift` | `OverlayCanvasZoomTests` | ✅ |
| `OverlayCoordinator.swift` | — | ✅ 多屏遮罩 |
| `OverlayWindow.swift` | — | ✅ |
| `OverlayWindowController.swift` | — | ✅ |
| `PinContentView.swift` | `PinWindowTests` | ✅ 钉图 |
| `PinGeometry.swift` | `PinGeometryTests` | — |
| `PinLiveTextDelegate.swift` | — | — |
| `PinPanel.swift` | — | — |
| `PinWindowController.swift` | `PinWindowTests` | ✅ |
| `QuickAccessControlsView.swift` | `QuickAccessTests` | — |
| `QuickAccessPanelController.swift` | `QuickAccessTests` | ✅ Quick Access |
| `QuickAccessVideoView.swift` | — | — |
| `QuickAccessView.swift` | `QuickAccessTests` | — |
| `SelectionCursor.swift` | — | ✅ 光标切换 |
| `SelectionGeometry.swift` | `SelectionGeometryTests` | — |

## UI/Annotation

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `InlineTextField.swift` | `InlineTextFieldTests` | — |
| `LiveTextOverlay.swift` | — | — |

## UI/DesignSystem

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `ArrowStylePicker.swift` | — | — |
| `BarButton.swift` | — | — |
| `ColorSwatchesView.swift` | `HUDSliderTests` (间接) | — |
| `FloatingSurface.swift` | — | — |
| `GlassControlButton.swift` | — | — |
| `GlassControls.swift` | — | — |
| `HUDCheckboxButton.swift` | — | — |
| `HUDSlider.swift` | `HUDSliderTests` | — |
| `RectCornerStylePicker.swift` | — | — |
| `SettingsComponents.swift` | — | — |
| `ShapeFillModePicker.swift` | — | — |
| `StyleIconPicker.swift` | — | — |
| `Theme.swift` | — | — |
| `Tooltip.swift` | `TooltipTests` | — |
| `VisualEffectView.swift` | — | — |
| `WindowChrome.swift` | — | — |

## UI/History

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `HistoryView.swift` | `HistoryCardTests` | — |

## UI/MenuBar

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `MenuBarController.swift` | `MenuBarTests` | — |

## UI/Onboarding

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `OnboardingCard.swift` | — | — |
| `OnboardingView.swift` | `MenuBarTests` (间接: OnboardingModel) | — |
| `OnboardingWindowController.swift` | — | — |

## UI/Permissions

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `AppBundleDragCard.swift` | — | — |
| `PermissionDragPanel.swift` | — | — |

## UI/Recording

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `RecordingBorderPanel.swift` | — | ✅ 录屏红框 |
| `RecordingControlPanel.swift` | — | ✅ 录屏 HUD |
| `GifExportPanel.swift` | — | — |
| `VideoQuickLookPresenter.swift` | — | — |
| `VideoTrimController.swift` | `VideoTrimmerTests`（时间文本） | — |

## UI/Scrolling

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `ScrollingCapturePanelController.swift` | — | ✅ 模式选择条 |
| `ScrollingPreviewPanel.swift` | — | ✅ 滚动预览 |

## UI/Settings

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `AboutSettingsPane.swift` | — | — |
| `AnnotationSettingsPane.swift` | — | — |
| `CaptureSettingsPane.swift` | — | — |
| `GeneralSettingsPane.swift` | — | — |
| `HotkeyRecorderView.swift` | — | — |
| `HotkeysSettingsPane.swift` | — | — |
| `PermissionSettingsPane.swift` | — | — |
| `QuickAccessSettingsPane.swift` | — | — |
| `RecordingSettingsPane.swift` | — | — |
| `SettingsDetailView.swift` | — | — |
| `SettingsNavigationState.swift` | — | — |
| `SettingsSection.swift` | — | — |
| `SettingsSidebarView.swift` | — | — |
| `SettingsSplitViewController.swift` | — | — |
| `SettingsToolbarController.swift` | — | — |
| `SettingsWindowController.swift` | — | — |

## UI/Translation

| 源文件 | 单元测试 | selftest |
|--------|----------|----------|
| `SystemTranslationPresenter.swift` | — | — |

## TestSupport（测试辅助）

| 文件 | 用途 |
|------|------|
| `InlineEditScaffold.swift` | 就地标注测试的共享脚手架 |
| `TestImage.swift` | 测试用小尺寸位图工厂 |
| `TestNSEvent.swift` | 合成 NSEvent 工具 |
| `TestUserDefaults.swift` | 独立 UserDefaults 工厂 |

---

## 覆盖薄弱区域

以下模块尚无单元测试且无 selftest 覆盖，需要在后续迭代中关注：

- `Core/Diagnostics/InteractionMetrics.swift` — 交互指标
- `Core/Settings/AppAppearance.swift` — 外观切换
- `Core/Settings/LaunchAtLogin.swift` — 开机启动
- `UI/Settings/*` — SwiftUI 设置面板（视图层，通常由 snapshot test 覆盖）
- `UI/DesignSystem/*` — 大部分设计系统组件（纯视图，依赖 SwiftUI Preview 验证）
- `UI/Translation/SystemTranslationPresenter.swift` — 系统翻译
