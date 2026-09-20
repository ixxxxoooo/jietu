#!/usr/bin/env swift
//
// 渲染 DMG 窗口的背景图，供 build-dmg.sh 使用。
//
// 出一份 background.png 就够了，它是 2 倍像素 + 144dpi：Finder 按「点」铺图，
// 在 Retina 上正好一个物理像素对一个像素，字才不虚。
// （别指望同目录再放个 background@2x.png——实测 Finder 不认，只会把 1x 放大。）
//
// 背景图承担两件事：一是让 DMG 窗口有设计感，二是把原来「00-请先读我.txt」里的
// 安装说明画进画面（图标位置由 build-dmg.sh 固定，所以文案能与之对齐）。
// 位置参数由 build-dmg.sh 统一给出，避免脚本与画面各写一份几何。
//
// 用法：
//   swift Scripts/dmg-background.swift --out <目录> --size 660x420 \
//       --app 200,210 --applications 460,210 \
//       --name Jietu --version 0.0.2 --repo github.com/ixxxxoooo/jietu
//
// @author ixxxxoooo
import AppKit

// MARK: - 参数

struct Config {
    var outDir = "."
    var width: CGFloat = 660
    var height: CGFloat = 420
    /// 出血：Finder 从 .DS_Store 恢复窗口时，内容区会比脚本设定的略宽略高，
    /// 画面比设计稿多画一圈，就不会在右边 / 下边露白边。设计稿本身仍对齐左上角。
    var bleed = CGSize(width: 16, height: 12)
    var app = CGPoint(x: 200, y: 210)
    var applications = CGPoint(x: 460, y: 210)
    var appName = "Jietu"
    var version = ""
    var repo = ""
}

func point(_ raw: String) -> CGPoint? {
    let parts = raw.split(separator: ",")
    guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
    return CGPoint(x: x, y: y)
}

func parseConfig() -> Config {
    var config = Config()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let flag = args.next() {
        guard let value = args.next() else { break }
        switch flag {
        case "--out": config.outDir = value
        case "--name": config.appName = value
        case "--version": config.version = value
        case "--repo": config.repo = value
        case "--size":
            if let p = point(value) { config.width = p.x; config.height = p.y }
        case "--bleed":
            if let p = point(value) { config.bleed = CGSize(width: p.x, height: p.y) }
        case "--app":
            if let p = point(value) { config.app = p }
        case "--applications":
            if let p = point(value) { config.applications = p }
        default:
            FileHandle.standardError.write("未知参数：\(flag)\n".data(using: .utf8)!)
        }
    }
    return config
}

// MARK: - 视觉令牌（取自 App 的 AccentColor #0D44E8）

let brand = NSColor(srgbRed: 0x0D / 255, green: 0x44 / 255, blue: 0xE8 / 255, alpha: 1)
let inkStrong = NSColor(srgbRed: 0x14 / 255, green: 0x16 / 255, blue: 0x1A / 255, alpha: 1)
let inkBody = NSColor(srgbRed: 0x39 / 255, green: 0x40 / 255, blue: 0x4C / 255, alpha: 1)
let inkSoft = NSColor(srgbRed: 0x5C / 255, green: 0x64 / 255, blue: 0x73 / 255, alpha: 1)
let inkFaint = NSColor(srgbRed: 0x86 / 255, green: 0x8E / 255, blue: 0x9C / 255, alpha: 1)

func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

/// 对齐到 0.5pt：2x 下正好是整像素，文字与线条不会因为半像素定位而发虚。
func snap(_ value: CGFloat) -> CGFloat {
    (value * 2).rounded() / 2
}

func text(_ string: String, _ f: NSFont, _ color: NSColor, kern: CGFloat = 0,
          baseline: CGFloat = 0) -> NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
    if kern != 0 { attributes[.kern] = kern }
    if baseline != 0 { attributes[.baselineOffset] = baseline }
    return NSAttributedString(string: string, attributes: attributes)
}

/// 以「顶部 y」定位、水平居中绘制，绘制原点在文本行框左上角。
func draw(_ string: NSAttributedString, centerX: CGFloat, topY: CGFloat) {
    let size = string.size()
    string.draw(in: NSRect(x: snap(centerX - size.width / 2), y: snap(topY),
                           width: size.width, height: size.height))
}

func draw(_ string: NSAttributedString, left: CGFloat, centerY: CGFloat) {
    let size = string.size()
    string.draw(in: NSRect(x: snap(left), y: snap(centerY - size.height / 2),
                           width: size.width, height: size.height))
}

// MARK: - 绘制

func renderImage(_ config: Config, scale: CGFloat) -> NSBitmapImageRep? {
    let width = config.width
    let height = config.height
    // 画布 = 设计稿 + 出血；下面所有坐标都还是设计稿坐标（左上角对齐）。
    let canvasW = width + config.bleed.width
    let canvasH = height + config.bleed.height
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          // 不带 alpha 通道：画面整幅不透明，RGBA 那份的 alpha 是白占体积
          // （同一张图 RGBA 1148KB → RGB 972KB，逐像素完全一致）。
          let cg = CGContext(data: nil,
                             width: Int(canvasW * scale),
                             height: Int(canvasH * scale),
                             bitsPerComponent: 8,
                             bytesPerRow: 0,
                             space: space,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }

    // 把 CTM 翻成「左上角为原点、y 向下」，同时把上下文标记为 flipped，
    // AppKit 的文字绘制才会跟着这套坐标走（只翻 CTM 会画倒字）。
    cg.translateBy(x: 0, y: canvasH * scale)
    cg.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    // 1. 底：斜向冷调渐变，左下最亮，右下收进一层极淡的冷灰。
    if let gradient = CGGradient(colorsSpace: space,
                                 colors: [NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).cgColor,
                                          NSColor(srgbRed: 0.957, green: 0.965, blue: 0.984, alpha: 1).cgColor,
                                          NSColor(srgbRed: 0.910, green: 0.925, blue: 0.957, alpha: 1).cgColor] as CFArray,
                                 locations: [0, 0.52, 1]) {
        cg.drawLinearGradient(gradient,
                              start: CGPoint(x: 0, y: 0),
                              end: CGPoint(x: canvasW, y: canvasH),
                              options: [])
    }

    // 2. 品牌光晕：垫在 App 图标后面，把视线拉到「源」上。
    if let glow = CGGradient(colorsSpace: space,
                             colors: [brand.withAlphaComponent(0.15).cgColor,
                                      brand.withAlphaComponent(0).cgColor] as CFArray,
                             locations: [0, 1]) {
        cg.drawRadialGradient(glow,
                              startCenter: config.app, startRadius: 0,
                              endCenter: config.app, endRadius: 215,
                              options: [])
        // 目标槽位给一层更淡的中性光，避免右侧空。
        cg.drawRadialGradient(CGGradient(colorsSpace: space,
                                         colors: [NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85).cgColor,
                                                  NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0).cgColor] as CFArray,
                                         locations: [0, 1])!,
                              startCenter: config.applications, startRadius: 0,
                              endCenter: config.applications, endRadius: 175,
                              options: [])
    }

    // 3. 顶部：一枚品牌色短脊 + 字标 + 版本 + 副标题。
    let centerX = width / 2
    let kicker = NSBezierPath(roundedRect: NSRect(x: centerX - 11, y: 34, width: 22, height: 3),
                              xRadius: 1.5, yRadius: 1.5)
    brand.withAlphaComponent(0.9).setFill()
    kicker.fill()

    var wordmark = text(config.appName, font(27, .semibold), inkStrong, kern: -0.4)
    if !config.version.isEmpty {
        wordmark = NSAttributedString(string: "\(config.appName) \(config.version)",
                                      attributes: [.font: font(27, .semibold),
                                                   .foregroundColor: inkStrong,
                                                   .kern: -0.4])
        let composed = NSMutableAttributedString(attributedString: wordmark)
        composed.addAttribute(.font, value: font(15, .medium),
                              range: (composed.string as NSString).range(of: config.version))
        composed.addAttribute(.foregroundColor, value: inkFaint,
                              range: (composed.string as NSString).range(of: config.version))
        composed.addAttribute(.kern, value: 0.2,
                              range: (composed.string as NSString).range(of: config.version))
        wordmark = composed
    }
    draw(wordmark, centerX: centerX, topY: 52)

    draw(text("拖拽到「应用程序」即可安装　·　Drag to Applications to install",
              font(12.5), inkSoft, kern: 0.1),
         centerX: centerX, topY: 90)

    // 4. 两槽位之间的虚线拖拽轨迹 + 箭头。
    let arrowY = (config.app.y + config.applications.y) / 2
    let startX = config.app.x + 58
    let endX = config.applications.x - 62
    let trail = NSBezierPath()
    trail.move(to: CGPoint(x: startX, y: arrowY))
    trail.line(to: CGPoint(x: endX - 6, y: arrowY))
    trail.lineWidth = 2
    trail.lineCapStyle = .round
    trail.setLineDash([0.5, 7], count: 2, phase: 0)
    brand.withAlphaComponent(0.3).setStroke()
    trail.stroke()

    let head = NSBezierPath()
    head.move(to: CGPoint(x: endX - 10, y: arrowY - 7))
    head.line(to: CGPoint(x: endX, y: arrowY))
    head.line(to: CGPoint(x: endX - 10, y: arrowY + 7))
    head.lineWidth = 2
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    brand.withAlphaComponent(0.55).setStroke()
    head.stroke()

    // 5. 底部提示：首次打开前需用命令行移除隔离属性。
    let hintY = max(config.app.y, config.applications.y) + 80
    draw(text("首次打开前请在终端执行：", font(12.5, .medium), inkBody),
         centerX: centerX, topY: hintY)
    draw(text("xattr -dr com.apple.quarantine /Applications/\(config.appName).app",
              NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), inkSoft),
         centerX: centerX, topY: hintY + 20)

    // 6. 页脚：仓库地址。
    if !config.repo.isEmpty {
        let footer = text(config.repo, font(11), inkFaint, kern: 0.2)
        let size = footer.size()
        footer.draw(in: NSRect(x: snap(width - 30 - size.width), y: snap(height - 30),
                               width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let image = cg.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    // 像素是 2 倍，尺寸按「点」报：PNG 里写成 144dpi，Finder 铺图时正好一个像素对一个物理像素。
    rep.size = NSSize(width: canvasW, height: canvasH)
    return rep
}

// MARK: - 入口

let config = parseConfig()
let outDir = URL(fileURLWithPath: config.outDir)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// 只出一份文件：Finder 只加载被指定的那个 PNG，同目录的 background@2x.png 它不认
// （实测逐像素比对：认 @2x 的话字会清晰，实际却是 1x 被放大）。所以这份本身就是 2 倍像素。
guard let rep = renderImage(config, scale: 2),
      let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("渲染背景图失败\n".data(using: .utf8)!)
    exit(1)
}
try data.write(to: outDir.appendingPathComponent("background.png"))
print("背景图已生成：\(outDir.path)/background.png (\(Int(rep.size.width))x\(Int(rep.size.height))pt @2x)")
