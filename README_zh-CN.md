<p align="center">
  <img src="Jietu/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Jietu 图标">
</p>

<h1 align="center">Jietu 截图</h1>

<p align="center">
  <b>原生 macOS 截图与录屏工具</b><br>
  截图、标注、钉图、录屏——数据全部留在本机。
</p>

<p align="center">
  <a href="https://github.com/ixxxxoooo/jietu/releases/latest"><img src="https://img.shields.io/github/v/release/ixxxxoooo/jietu?style=flat-square" alt="Release"></a>
  <a href="https://github.com/ixxxxoooo/jietu/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ixxxxoooo/jietu/ci.yml?branch=main&style=flat-square&label=CI" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-6-orange?style=flat-square" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/ixxxxoooo/jietu?style=flat-square" alt="License"></a>
  <a href="README.md">🇬🇧 English</a>
</p>

---

## ✨ 功能

### 截图
- **区域截图** — 绿色虚线选框 + 十字准线 + 尺寸标签，像素级精准
- **窗口截图** — 自动识别窗口边界，绿色粗线吸附；可选 macOS 风格阴影
- **全屏截图** — 抓取鼠标所在的整块屏幕
- **定时截图** — 3 / 5 / 10 秒延迟
- **滚动长图** — 框选区域后滚动内容，自动拼成长图（手动 / 自动滚动）
- **多显示器** — 所有屏幕同时进入选区状态

### 录屏
- **区域 / 窗口 / 全屏** 三种取景模式
- **系统声音 + 麦克风** 录制，实时混音
- **暂停 / 继续** — 暂停段无缝移除
- MP4（H.264），30/60 fps，自动码率
- 录完可 **裁剪** 成片、**导出 GIF**

### 标注（对象化，全程可改）
- 工具：选择、矩形、椭圆、箭头、直线、画笔、高亮笔、聚光灯、马赛克、模糊、文字、序号、橡皮、裁剪
- 原地编辑 — 截完直接在遮罩层上标注
- 移动 / 缩放 / 旋转手柄；撤销 / 重做（⌘Z / ⇧⌘Z）
- 跨会话记忆默认样式

### 更多
- 🔍 **实况文本（OCR）** — 在截图或钉图上选择并复制文字
- 🌐 **翻译** — 调用 macOS 自带的翻译框架
- 📌 **钉图** — 拖拽缩放、滚轮缩放、双击关闭
- 🎨 **取色器** — 放大镜取色，直接复制色号
- ⌨️ **全局热键** — 8 个可自定义动作（默认不绑定）
- 🌙 **主题** — 跟随系统 / 浅色 / 深色
- 🌍 **多语言** — 中文与英文，根据系统语言自动切换

## 📦 安装

### 下载 DMG

从 [Releases](https://github.com/ixxxxoooo/jietu/releases/latest) 下载最新 `.dmg`，打开后将 `Jietu.app` 拖入 `/Applications`。

> **首次打开提示**：本应用使用自签名证书（无 Developer ID / 公证），macOS Gatekeeper 会拦截首次启动。放行方式：
>
> - 右键 App → **打开** → 确认，**或者**
> - 执行 `xattr -dr com.apple.quarantine /Applications/Jietu.app`

### 授权

1. **屏幕录制**（必需）— 前往 **系统设置 › 隐私与安全性 › 屏幕录制**，添加 Jietu，然后 **重启应用**（macOS 要求重启后才生效）。
2. **辅助功能**（可选）— 仅用于滚动长图的自动滚动。前往 **系统设置 › 隐私与安全性 › 辅助功能** 添加 Jietu，无需重启。

## 🛠 从源码构建

### 环境要求

- macOS 26+（Tahoe）
- Xcode 26+ / Swift 6

### 构建

```bash
# Debug 构建（Jietu Dev.app — 独立 bundle ID，不干扰正式版）
xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build build

# 运行
open ".build/Build/Products/Debug/Jietu Dev.app"
```

### 测试

```bash
xcodebuild -project Jietu.xcodeproj -scheme Jietu -configuration Debug \
  -destination 'platform=macOS' test
```

### 打包 DMG（Release）

```bash
bash Scripts/build-dmg.sh
# 产物：dist/Jietu-<版本>.dmg
```

## 🏗 架构

```
Jietu/
  App/            应用入口与 AppDelegate（流程编排）
  Core/
    Annotation/   标注模型、几何、命中测试、渲染器
    Capture/      ScreenCaptureKit 捕获、坐标换算、像素采样
    Diagnostics/  DEBUG 命令行自检
    History/      最近记录历史
    Hotkeys/      Carbon 全局热键、标注编辑器内快捷键
    ImageIO/      裁剪 / 编码 / 落盘 / 剪贴板 / 快门音
    Notifications/系统通知
    OCR/          Vision 文字识别
    Permissions/  屏幕录制、辅助功能
    Recording/    录屏引擎、双路混音、编码参数、GIF 导出
    Scrolling/    自动滚动、行签名拼接
    Settings/     设置存储、登录项
  Overlay/        遮罩画布、选区交互、原地工具栏、浮窗、钉图
  UI/
    DesignSystem/ 主题与玻璃控件
    MenuBar/      状态栏菜单
    Settings/     偏好设置
    ...           其它 UI 模块
  Resources/      资源文件、本地化字符串（en / zh-Hans）
JietuTests/       单元测试
Scripts/          构建与开发脚本
```

## 🤝 贡献

请参阅 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。
