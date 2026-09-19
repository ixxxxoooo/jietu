# AGENTS.md

## 修改后必做的三步

每次改动代码后，按顺序完成：**重新构建 → 重启 App → 提交 git**。

```bash
# 1 + 2. 构建 → 重启 → 校验（推荐，一条命令搞定）
bash Scripts/restart-dev.sh

# 3. 提交
git add -A && git commit -m "<type>: <描述>"
```

**必须校验「跑的就是刚构建的那个」**：`xcodebuild`（尤其 `test`）会刷新产物 mtime，
而正在跑的进程可能还是上一次构建的。`Scripts/restart-dev.sh` 会比较
「进程启动时刻」与「产物 mtime」，发现跑旧了自动再重启一次，并打印
实例数 / 产物 mtime / 进程启动时刻 / 进程路径 —— 每次改完都看这几行。
（手动等价物：`xcodebuild ... build` → `pkill -f "Build/Products/Debug/Jietu Dev.app"` →
`open ".build/Build/Products/Debug/Jietu Dev.app"`。）

- 构建必须成功（`** BUILD SUCCEEDED **`）才能提交。
- 签名保持默认的自签名证书 `Jietu`，不要加 `CODE_SIGNING_ALLOWED=NO`，否则重签名会丢「屏幕录制」授权。
- 提交信息沿用仓库风格：`feat:` / `fix:` / `change:` / `docs:` 等前缀。
- 提交信息（subject 与 body）**一律用英文**，PR 标题与描述同理；仓库历史里的中文提交不追改。
  代码注释、本文档与 `开发进度.md` 仍按原样用中文。

## 代码组织规范（写 / 改代码前必读）

以下规则是既有重构（89bb7a6…a04e05a）沉淀的既成标准，新代码必须遵守，不每次自行判断。

### 单文件规模

- 主体代码软上限 **~500 行**，接近 400 行就该拆；按职责拆够即停，不为凑行数机械切。
- 小于 ~50 行的小类型**不单独立文件**，聚在相关文件里；文件里出现多个平等类型才"一类型一文件"。
- **自查（必做）**：提交前对新增 / 明显变长的文件跑 `wc -l`，超过 500 行先按下面的规则拆，再提交。

### 文件拆分规则（按序适用）

1. **大类 → 主文件 + `+功能域` extension**：主文件只留生命周期 / 装配，每个 extension 自成一个功能域。
   例：`OverlayCanvasView.swift` + `OverlayCanvasView+Selection.swift` / `+Actions` / `+Zoom` …；
   `AppDelegate.swift` + `AppDelegate+Capture.swift` / `+Recording` / `+Scrolling` …
2. **多类型文件 → 一类型一文件**；纯数据类型外置成独立文件（如 `SettingsTypes.swift`）。
3. **重复代码 → 抽公共组件 / 工厂**，禁止靠拷贝解决。
4. **死代码直接删**（连同注释掉的代码），不留"以后可能用"。

### 分层与依赖

```
App/（生命周期、装配） → Overlay/（截图遮罩层） 与 UI/（常驻界面） → Core/（无 UI 业务核心，按领域分目录）
```

- 依赖只允许沿箭头方向，**Core 不 import 界面层**、UI 不直接戳 Core 内部实现。
- **UI 样式唯一来源是 `UI/DesignSystem/`**（`Theme`、`.floatingSurface()`、玻璃组件）：
  新界面禁止散写颜色 / 圆角 / 投影，一律走设计系统令牌。

### 测试

- **一源码文件一测试文件**，同名对应（`InlineAnnotationToolbar` → `InlineToolbarModelTests` 等）；单测文件 ≤~700 行，超了按聚焦拆。
- 共享脚手架（`makeDefaults` / `solidImage` / `fakeMouseEvent` 这类工厂）**只放 `JietuTests/TestSupport/`**，禁止在测试文件里重复定义；拆分大测试文件时配套更新 `COVERAGE.md` 对照表。

### 已知例外

`Jietu/Core/Diagnostics/CaptureSelfTest.swift`（~3200 行）是存量遗留的自测脚本。**新代码不得模仿它的体量**；哪次改到它，就顺手按规则 1 拆掉。

## 构建渠道（Debug = dev）

Debug 构建是**独立的开发渠道**，配置在 `Jietu.xcodeproj` 的 Debug configuration 里：

| | Debug | Release |
|---|---|---|
| `PRODUCT_NAME` | `Jietu Dev` | `Jietu` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.ixxxxoooo.jietu.dev` | `com.ixxxxoooo.jietu` |
| `PRODUCT_MODULE_NAME` | `Jietu`（固定，否则 `@testable import Jietu` 会断） | `Jietu` |
| 产物路径 | `.build/Build/Products/Debug/Jietu Dev.app` | `.../Release/Jietu.app` |

- 独立 bundle id = 独立的 TCC 授权 / 偏好 / 登录项，本地调试不会污染正式版。
- 系统设置的「屏幕录制」列表里，Debug 显示为 **Jietu Dev**；设置页「权限 › 授权对象」
  与权限引导都会把当前身份（含 `dev` 标记）显示出来，照着勾选即可。
- 改了渠道相关的 build setting 后，`JietuTests` 的 `TEST_HOST` 也要同步指向
  `Jietu Dev.app/Contents/MacOS/Jietu Dev`（Debug 侧已就位）。
- **Debug 必须 `ENABLE_DEBUG_DYLIB = NO`**（已写进 Debug 配置）。Xcode 16+ 默认把 Debug 的
  真代码放进 `Jietu Dev.debug.dylib`、主可执行文件只留 ~58KB 的壳；那样 TCC 拿不到稳定的
  签名身份，「屏幕录制」授权会出现「API 说已授权、列表里却看不到这个 App」的怪状态。
  关掉后主可执行文件是完整二进制（~6.5MB）。

## 单实例

Debug / Release 各自只有一个实例：

- 走 LaunchServices 正常启动（`open` / 状态栏 / 登录项）本来就只会有一个实例；
- `AppDelegate.handOffToExistingInstance()` 兜底：已有同 bundle id 实例时，
  把前台交给它再退出自己（直接运行二进制、或用 `open -n` 强制多开时靠这条收敛）。
  **跑单元测试时这条守卫会跳过**（测试宿主就是同一个 App bundle，App 通常正开着）。
- 刻意**不用** `LSMultipleInstancesProhibited`：它没法绕过，会让 `xcodebuild test`
  的测试宿主起不来。

**不要用 `open -n`**——`-n` 就是「强制开新实例」，正是多实例的来源。「重启 Jietu」
走的是「起一个后台 shell 等旧进程退出、再 `open`」，所以重启前后都只有一个实例。

## 权限：辅助功能

只用于**滚动长图的自动滚动**（合成滚轮事件投给别的 App，`CGEvent.post` 没有这个权限会静默失效）。

- 状态是**现读**的（`AXIsProcessTrusted()`），授权后**不用重启**（与屏幕录制不同）。
- 授权入口：设置页「权限 › 辅助功能」的「拖拽授权…」（复用同一个拖拽面板）、
  或触发自动滚动时弹出的引导（会顺带申请一次）。
- 系统设置的「辅助功能」列表同样接受拖入；自签名 / Debug 构建可能不自动出现，用拖拽即可。
- 没授权也不影响其它功能：滚动长图会退回**手动滚动**。

## 权限排查（屏幕录制）

- 判断权限**别只看系统设置的列表**：自签名 / Debug 构建可能不在列表里，但授权照样生效。
  以 `CGPreflightScreenCaptureAccess()` 和实际能否截图为准。
- 让 App 出现在列表里，两条路：
  1. 点该栏左下的 **`+`** 手动选中 `Jietu Dev.app`；
  2. 菜单栏 **「拖拽授权「屏幕录制」…」**：打开系统设置并浮出一个面板，把里面的 App 卡片
     拖进列表即可（那一栏接受拖入）。实现见 `UI/Permissions/`，用 `CGWindowList` 定位系统设置
     窗口，**不需要辅助功能权限**。
- 自签名证书 `Jietu` 目前**未经信任**（`security find-identity -v -p codesigning` 里没有它）。
  想让它自动出现 / 让授权在重编译后更稳，可在「钥匙串访问 › 登录 › Jietu › 显示简介 › 信任」
  把「代码签名」设为「始终信任」。
- 授权入口**只有拖拽**：菜单栏「拖拽授权「屏幕录制」…」/ 设置页「拖拽授权…」。
  刻意不提供 `tccutil reset ScreenCapture <bundle id>` 这类「清记录重来」的入口——
  它会清掉当前**已经生效**的授权，代价大于收益。

## 标注工具栏规范

标注界面现已**全量统一收敛至原地编辑工具栏**（`Jietu/Overlay/InlineAnnotationToolbar.swift`，位于全屏遮罩 `OverlayCanvasView` 的选区下方）：
- **单一事实来源（Single Source of Truth）**：已彻底废除独立编辑窗口，截图立即编辑、浮窗卡片点击编辑、钉图编辑、菜单栏历史记录编辑全部走居中原地编辑；
- **二级菜单居中展开**：点击工具时在主工具栏下方水平居中展开二级参数栏；
- **设计系统样式**：采用 `.floatingSurface()` 磨砂面板、Theme 墨色 scrim、连续圆角与微投影。

