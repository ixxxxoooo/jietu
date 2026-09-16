# Jietu 截图

原生 macOS 截图工具（对标 CleanShot）。菜单栏常驻（LSUIElement），
ScreenCaptureKit 冻结全屏 + 全屏遮罩选区，支持就地标注与独立编辑窗口两种编辑方式。

## 功能

### 截图
- 区域截图：绿色虚线选框 + 圆形控制点，像素级精准、Retina 原生分辨率
- 窗口截图：自动识别窗口边界，**绿色粗线**吸附，单击即贴边截取
- 全屏截图、定时截图（3 / 5 / 10 秒）
- 多显示器：所有屏幕同时进入选区状态

### 全局热键（可在设置页逐个改写）
- 区域截图 `⌘⇧A`、窗口截图 `⌘⇧W`、全屏截图 `⌘⇧F`、定时截图（5 秒）`⌘⇧T`
- 与其它 App / 本 App 其它动作撞车时自动回滚到原组合键并提示

### 标注（对象化，全程可改）
- 工具：选择、矩形、椭圆、箭头、画笔、高亮、马赛克、文字、序号、橡皮
- 移动 / 8 点缩放 / 旋转手柄；箭头端点与曲线；序号引线
- 文字就地输入、双击改文案；颜色、线宽、字号、马赛克块大小均可事后修改
- 橡皮为画笔式擦除，露出底层画面，可调大小
- 撤销 / 重做（快照式，⌘Z / ⇧⌘Z）

### 编辑方式（设置可切换）
- **就地编辑**：选区确定后，工具栏就在选框下方弹出，直接在截图上标注，✓ / ✗ 决定
- **独立窗口**：截图先进浮窗，点击浮窗在单独窗口里编辑

### 实况文本（类 Apple Live Text）
- 点工具栏「识别文字」自动进入选择工具并开启实况文本，悬停变文本光标，直接拖选复制
- 钉图同样支持（点右下角实况文本按钮）

### 交付
- Quick Access 浮窗：只显示图片预览；悬停出现四角圆形按钮（复制/标注/钉图/关闭）+ 中间保存
- 多个截图队列堆叠（最新在上），到点向屏幕边缘侧滑；可配置停靠位置与自动关闭时间
- 钉图：可拖动、拖边缩放、滚轮缩放、双击关闭、原地钉
- 保存：PNG / JPEG（质量可调）、剪贴板（PNG + TIFF）、快门音
- 文件名模板：`{date}` / `{time}` / `{datetime}` / `{counter}`，默认 `Jietu {date} at {time}`
- 保存反馈：菜单栏图标闪烁 + 系统通知（带缩略图，点击在访达中定位），可关闭
- 最近截图缩略图子菜单、截图历史面板、打开截图文件夹、登录时启动

## 环境要求
- macOS 26+（使用 Liquid Glass、VisionKit ImageAnalysisOverlayView）
- Xcode 26+ / Swift 6

## 构建与运行

```bash
# 构建（工程使用自签名证书 Jietu；无证书可加 CODE_SIGNING_ALLOWED=NO 临时签名）
xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration Debug \
  -destination 'platform=macOS' build

# 单元测试
xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration Debug \
  -destination 'platform=macOS' test
```

首次运行需授予「屏幕录制」权限；授权后必须**重启 App**（macOS 限制）。

### 命令行自检（DEBUG-only）

```bash
Jietu --selftest-capture <输出目录>        # 冻结全部屏幕 → 落 PNG → 打印报告
Jietu --selftest-overlay <秒数> <输出目录>  # 冻结屏幕 → 弹遮罩 → 保持 N 秒
Jietu --selftest-onboarding <秒数>         # 权限引导窗自检
```

## 目录结构

```
Jietu/
  App/            应用入口与 AppDelegate（流程编排）
  Core/
    Capture/      ScreenCaptureKit 捕获、坐标换算、像素采样、窗口信息
    Annotation/   标注模型、几何、命中测试、渲染器
    Hotkeys/      Carbon 全局热键
    ImageIO/      裁剪 / 编码 / 落盘 / 剪贴板 / 快门音
    Permissions/  屏幕录制权限
    Settings/     设置存储、登录项
    OCR/          Vision 文字识别
    Diagnostics/  DEBUG 命令行自检
  Overlay/        遮罩画布、选区交互、就地工具栏、Quick Access 浮窗、钉图
  UI/
    Annotation/   标注编辑窗口、实况文本覆盖层
    Settings/     偏好设置（左分类 + 右内容）
    History/      截图历史面板
    MenuBar/      状态栏菜单
    Onboarding/   权限引导
    DesignSystem/ 主题与磨砂背景
JietuTests/       Swift Testing 单元测试
```

## 单元测试覆盖
- 选区几何（矩形 / 锁比 / 调整 / 平移 / 命中）
- 坐标换算（cg ↔ appKit ↔ local）、Y 轴翻转、缩放
- 截图裁剪、PNG/JPEG 编码与落盘、同名追加序号、文件名模板展开与序号推断
- 热键显示串与组合键解析、多热键默认值与持久化、旧版单热键迁移
- 设置读写与默认值、最近截图队列
- 标注渲染（矩形描边 / 序号圆点 / 马赛克成块）与标注几何（平移 / 缩放 / 旋转 / 端点）

## 说明
- 「屏幕录制」授权对已运行进程不生效，需重启（代码内含引导）
- 就地编辑的橡皮擦除使用清空混合，导出 PNG 中被擦处为透明

## 作者
@author ixxxxoooo
