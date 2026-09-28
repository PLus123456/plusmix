// 生成 Samples/ 下的字幕 / 台标 PNG（W4-C）。只用系统框架，不依赖仓库里的包：
//
//     swift Samples/tools/make-assets.swift            # 写 Samples/{church,classroom,event}/assets/*.png
//
// 每张图都是 1920×1080、带 alpha 的整幅画（叠加通道的 rect 用整个画面，图里透明的地方就是透出 PGM 的地方），
// 与 scenarios/g4-stinger.png 同一种用法。字幕条放在下三分之一（0.78–0.95 倍高），台标放右上（0.08–0.16 倍高、避开合成源右上角的闪光块）。
// 换成自己的素材：任何同尺寸、带 alpha 的 PNG 直接覆盖同名文件即可，节目文件不用改。
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let width = 1920, height = 1080

func makeContext() -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    return ctx
}

/// 顶点在左上的坐标 → CoreGraphics（原点左下）。
func rect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
    CGRect(x: x * CGFloat(width), y: CGFloat(height) - (y + h) * CGFloat(height), width: w * CGFloat(width), height: h * CGFloat(height))
}

func font(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
    NSFont(name: weight == .bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
}

/// 在 (x, baselineY)（左上坐标系里的基线位置）画一行文字。
func draw(_ text: String, in ctx: CGContext, x: CGFloat, baselineY: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font(size, weight: weight), .foregroundColor: color.cgColor]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: x * CGFloat(width), y: CGFloat(height) - baselineY * CGFloat(height))
    CTLineDraw(line, ctx)
}

func fill(_ r: CGRect, color: NSColor, radius: CGFloat, in ctx: CGContext) {
    ctx.setFillColor(color.cgColor)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
}

/// 下三分之一字幕条：深色半透明底 + 左侧色条 + 两行字。
func lowerThird(title: String, subtitle: String, accent: NSColor) -> CGContext {
    let ctx = makeContext()
    fill(rect(x: 0.06, y: 0.78, w: 0.88, h: 0.17), color: NSColor(white: 0.08, alpha: 0.82), radius: 14, in: ctx)
    fill(rect(x: 0.06, y: 0.78, w: 0.012, h: 0.17), color: accent, radius: 4, in: ctx)
    draw(title, in: ctx, x: 0.095, baselineY: 0.857, size: 64, weight: .bold, color: .white)
    draw(subtitle, in: ctx, x: 0.095, baselineY: 0.925, size: 38, weight: .regular, color: NSColor(white: 0.85, alpha: 1))
    return ctx
}

/// 右上台标：圆形徽记 + 一行字。胶囊的宽按文字量出来，右边缘贴在 0.97 倍宽。
func logo(text: String, accent: NSColor) -> CGContext {
    let ctx = makeContext()
    let attrs: [NSAttributedString.Key: Any] = [.font: font(40, weight: .bold), .foregroundColor: NSColor.white.cgColor]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let h = 0.08 * CGFloat(height)
    let w = h + 24 + textWidth + 40                       // 徽记 + 间距 + 文字 + 右边距
    let badge = CGRect(x: 0.97 * CGFloat(width) - w, y: CGFloat(height) - 0.16 * CGFloat(height), width: w, height: h)
    fill(badge, color: NSColor(white: 0.08, alpha: 0.75), radius: h / 2, in: ctx)
    let circle = CGRect(x: badge.minX + 10, y: badge.minY + 10, width: h - 20, height: h - 20)
    ctx.setFillColor(accent.cgColor)
    ctx.fillEllipse(in: circle)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: circle.insetBy(dx: circle.width * 0.3, dy: circle.height * 0.3))
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: badge.minX + h + 24, y: badge.minY + h * 0.33)
    CTLineDraw(line, ctx)
    return ctx
}

func write(_ ctx: CGContext, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-assets", code: 1, userInfo: [NSLocalizedDescriptionKey: "建不了 PNG：\(path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "make-assets", code: 2, userInfo: [NSLocalizedDescriptionKey: "写不出 PNG：\(path)"]) }
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    print("写入 \(path)（\(size / 1024) KB）")
}

// Samples/ 目录 = 本脚本所在目录的上一级
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let samples = scriptURL.deletingLastPathComponent().deletingLastPathComponent().path

let blue = NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1)
let orange = NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.15, alpha: 1)
let green = NSColor(calibratedRed: 0.25, green: 0.75, blue: 0.45, alpha: 1)

do {
    try write(lowerThird(title: "歌词字幕示例 · 第 1 节", subtitle: "把你的歌词放在这里 —— 换成同尺寸、带 alpha 的 PNG 即可", accent: blue),
              to: "\(samples)/church/assets/lyrics.png")
    try write(logo(text: "教会直播 · 示例台标", accent: blue), to: "\(samples)/church/assets/logo.png")
    try write(lowerThird(title: "课程标题示例", subtitle: "第 3 讲 · 在这里写课程名与讲师（换图即可）", accent: green),
              to: "\(samples)/classroom/assets/title.png")
    try write(lowerThird(title: "活动名称示例 · 主会场", subtitle: "演讲人姓名 · 单位（换图即可）", accent: orange),
              to: "\(samples)/event/assets/title.png")
} catch {
    FileHandle.standardError.write(Data("make-assets: \(error.localizedDescription)\n".utf8))
    exit(1)
}
