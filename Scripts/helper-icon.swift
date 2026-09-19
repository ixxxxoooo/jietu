#!/usr/bin/env swift
//
// 渲染 Fix Gatekeeper.app 的图标，输出一个 .iconset 目录（由 build-dmg.sh 交给 iconutil 打包）。
//
// 为什么要自绘：osacompile 会白送一套通用图标资源（Assets.car 409KB + applet.icns 55KB），
// 加上启动器本身也才 588KB——那两坨占了这个小工具七成体积，而且图形是通用的
// 「卷轴＋印章」，放在 DMG 里既不说明用途也不好看。
//
// 用法：swift Scripts/helper-icon.swift --out <iconset 目录>
//
// 造型：琥珀色圆角方块 + 白色盾牌勾（与 Jietu.app 的品牌蓝方块明显区分，
// 也不撞系统蓝的「应用程序」文件夹）。琥珀取自 App 设计系统里的 warning 色系。
//
// 只出到 512px 档：DMG 里图标按 100pt 显示，100pt@2x 才 200px，512px 早就够了；
// 多带 512pt/1024px 两档会白涨 70KB。
//
// @author ixxxxoooo
import AppKit

/// 平铺的琥珀色：不用渐变——渐变会让这枚 PNG 大 90KB（47KB → 117KB），
/// 而这种尺寸下平涂已经足够好看。
let tileFill = CGColor(srgbRed: 0xF7 / 255, green: 0xA6 / 255, blue: 0x1B / 255, alpha: 1)
let glyph = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.97)

/// iconset 需要的档位：文件名 → 像素边长。
let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
]

func renderIcon(size: CGFloat) -> Data? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let cg = CGContext(data: nil, width: Int(size), height: Int(size),
                             bitsPerComponent: 8, bytesPerRow: 0, space: space,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // 翻成「左上角原点、y 向下」，排版直觉和背景图脚本一致。
    cg.translateBy(x: 0, y: size)
    cg.scaleBy(x: 1, y: -1)
    cg.setAllowsAntialiasing(true)

    // 1. 圆角方块：四周留 5.5%，圆角半径按 macOS 那套比例（边长 22.4%）。
    let inset = size * 0.055
    let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tilePath = CGPath(roundedRect: tile,
                          cornerWidth: tile.width * 0.224, cornerHeight: tile.width * 0.224,
                          transform: nil)
    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()
    cg.setFillColor(tileFill)
    cg.fill(tile)
    cg.restoreGState()

    // 2. 盾牌：圆角顶边 + 收成圆钝的底尖，白描边。
    let shieldW = tile.width * 0.50
    let shieldH = shieldW * 1.06
    let x0 = tile.midX - shieldW / 2
    let y0 = tile.midY - shieldH / 2 - tile.height * 0.005
    let x1 = x0 + shieldW
    let r = shieldW * 0.16
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: x0 + r, y: y0))
    shield.addLine(to: CGPoint(x: x1 - r, y: y0))
    shield.addQuadCurve(to: CGPoint(x: x1, y: y0 + r), control: CGPoint(x: x1, y: y0))
    shield.addLine(to: CGPoint(x: x1, y: y0 + shieldH * 0.55))
    shield.addCurve(to: CGPoint(x: tile.midX, y: y0 + shieldH),
                    control1: CGPoint(x: x1, y: y0 + shieldH * 0.80),
                    control2: CGPoint(x: x0 + shieldW * 0.70, y: y0 + shieldH * 0.93))
    shield.addCurve(to: CGPoint(x: x0, y: y0 + shieldH * 0.55),
                    control1: CGPoint(x: x0 + shieldW * 0.30, y: y0 + shieldH * 0.93),
                    control2: CGPoint(x: x0, y: y0 + shieldH * 0.80))
    shield.addLine(to: CGPoint(x: x0, y: y0 + r))
    shield.addQuadCurve(to: CGPoint(x: x0 + r, y: y0), control: CGPoint(x: x0, y: y0))
    shield.closeSubpath()
    cg.addPath(shield)
    cg.setStrokeColor(glyph)
    cg.setLineWidth(max(1, shieldW * 0.075))
    cg.setLineJoin(.round)
    cg.setLineCap(.round)
    cg.strokePath()

    // 3. 盾牌里的勾：按盾牌的宽高定尺寸，落在盾牌上半部（下半部在收尖，视觉重心偏上）。
    let checkW = shieldW * 0.44
    let checkH = shieldH * 0.26
    let checkCenter = CGPoint(x: tile.midX, y: y0 + shieldH * 0.42)
    let check = CGMutablePath()
    check.move(to: CGPoint(x: checkCenter.x - checkW / 2, y: checkCenter.y + checkH * 0.18))
    check.addLine(to: CGPoint(x: checkCenter.x - checkW * 0.10, y: checkCenter.y + checkH * 0.5))
    check.addLine(to: CGPoint(x: checkCenter.x + checkW / 2, y: checkCenter.y - checkH * 0.5))
    cg.addPath(check)
    cg.setStrokeColor(glyph)
    cg.setLineWidth(max(1, shieldW * 0.10))
    cg.setLineJoin(.round)
    cg.setLineCap(.round)
    cg.strokePath()

    guard let image = cg.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

// MARK: - 入口

var outDir = "."
var args = CommandLine.arguments.dropFirst().makeIterator()
while let flag = args.next() {
    guard let value = args.next() else { break }
    if flag == "--out" { outDir = value }
}
let dir = URL(fileURLWithPath: outDir)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

for (name, size) in variants {
    guard let data = renderIcon(size: size) else {
        FileHandle.standardError.write("渲染图标失败（\(Int(size))px）\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: dir.appendingPathComponent(name))
}
print("图标已生成：\(dir.path)（\(variants.count) 档）")
