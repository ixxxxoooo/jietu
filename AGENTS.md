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

## 发布（DMG / Release）

打 tag（`v*`）会触发 `.github/workflows/release.yml` → `bash Scripts/build-dmg.sh`：
构建、签名、窗口排版、打包、复验全在这一个脚本里，workflow 不再单独 `xcodebuild`
（那样会绕开脚本里的签名回退，之前三次 Release 就是挂在 `No certificate matching 'Jietu'`）。

- **签名身份必须稳定**（这条最要紧，TCC 授权全压在它上面）：
  用同一张自签名证书 `Jietu` 签出来的 App，设计要求（designated requirement）是
  `identifier "com.ixxxxoooo.jietu" and certificate leaf = H"aec7af8f…"`，
  **重装 / 升级 / 换机器构建都认同一份「屏幕录制」授权**；ad-hoc 签出来的设计要求会退化成
  `cdhash H"…"`——那是「这一个二进制」的指纹，**每构建一次就换一个身份**，用户每次升级都得
  重新授权一次，而且重拖也救不回来（列表里那一行早就在了，拖不出第二行）。
  所以 `build-dmg.sh` 取不到 `Jietu` 证书时**直接拒绝出包**，只认 `JIETU_ALLOW_ADHOC=1`
  这个显式降级；出包时会打印实际的「身份」一行，本地和 CI 应该看到同一串。
  - CI 的一次性配置：把证书连同私钥导出成 `.p12`，填进两个仓库 secret
    （`JIETU_CERT_P12_BASE64`、`JIETU_CERT_P12_PASSWORD`），`release.yml` 会把它导进
    临时钥匙串再签名。导出（本机钥匙串登录项里有这张证书，注意是**连同私钥**）：
    ```bash
    security export -t identities -f pkcs12 -k ~/Library/Keychains/login.keychain-db \
      -P "<给 p12 的密码>" -o /tmp/jietu.p12
    base64 -i /tmp/jietu.p12 | pbcopy   # 粘进 JIETU_CERT_P12_BASE64
    rm -P /tmp/jietu.p12
    ```
  - 已经中招（列表里那一行是旧身份留下的死记录、开关开着却仍是未授权）：在系统设置里
    选中那一行按 `−` 删掉，再把 App 拖回去、打开开关、重启 Jietu。
- **镜像工具**：优先 `diskutil image`（macOS 26+），旧系统回退 `hdiutil`，脚本自己探测；
  可用 `JIETU_IMAGE_TOOL=diskutil|hdiutil` 强制某条路径做验证。
- **窗口版式**（背景图 + 图标位置）靠 Finder 把设置写进镜像的 `.DS_Store`：本机排不上直接失败
  （那是真 bug）；CI 上拿不到 Finder 自动化授权则跳过并打 `::warning::`，DMG 照样出，
  只是回到系统默认版式。三个槽位（App / Applications / 安装说明）的几何只在
  `build-dmg.sh` 的「DMG 版式」一节里写一次。
- **可复制的安装命令**：`xattr -dr com.apple.quarantine …` 必须随镜像带一份**真文件**
  （`安装说明.txt`）。背景图上那行字是 PNG 像素，选不中也复制不了；
  更不能塞 `.command` / `.app`——从下载来的 DMG 里第一次打开会被 Gatekeeper 拦掉
  （「解隔离的工具自己也被隔离」，已经踩过两次）。这份说明**保持最短**：只讲「打开前做什么」，
  授权那套流程由 App 自己的引导页负责，别在这儿再抄一份。
- **体积**：两处都别动，动了 DMG 会悄悄变大——最终压缩格式用 LZMA（`ULMO`，比 zlib 省约 18%）；
  窗口背景图是不带 alpha 的 RGB（带 alpha 白涨约 180KB）。这几条 `build-dmg.sh` 里都有守门。
- 只想验打包流程、不发布：在 Actions 里手动跑 `Release`（`workflow_dispatch`），
  它只构建并上传 artifact，不建 release。
- CI 与 Release 都跑在 **`macos-26`** runner 上：工程部署目标是 macOS 26，
  macos-15 上既没有 Xcode 26，测试宿主也起不来。

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

