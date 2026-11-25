// ドット絵のロゴ（PNG）からアプリアイコンを作る
// 使い方: swift scripts/make-icon.swift Resources/Logo.png build/AppIcon.icns       （Mac 版の .icns）
//         swift scripts/make-icon.swift Resources/Logo.png <出力>.png               （iPad 版の 1024×1024。角丸と影なし、不透明）
// ロゴの透明な縁は読むときに切り落とす。ドットは整数倍で拡大し、ぼかさない
import AppKit

let args = CommandLine.arguments
guard args.count == 3,
      let data = FileManager.default.contents(atPath: args[1]),
      let src = NSBitmapImageRep(data: data) else {
    FileHandle.standardError.write("usage: make-icon.swift <logo.png> <out.icns|out.png>\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: args[2])

/// ロゴのドット。y は上から数える
struct Dot { let x: Int, y: Int, color: CGColor }
var dots: [Dot] = []
for y in 0..<src.pixelsHigh {
    for x in 0..<src.pixelsWide {
        guard let c = src.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0 else { continue }
        dots.append(Dot(x: x, y: y, color: c.cgColor))
    }
}
guard !dots.isEmpty else {
    FileHandle.standardError.write("ロゴが透明だけです\n".data(using: .utf8)!)
    exit(1)
}
// 透明な縁を除いた範囲
let minX = dots.map(\.x).min()!, maxX = dots.map(\.x).max()!
let minY = dots.map(\.y).min()!, maxY = dots.map(\.y).max()!
let logoW = maxX - minX + 1, logoH = maxY - minY + 1

/// box（下原点、px 単位）の中央に、収まる最大の整数倍でロゴを描く
func drawLogo(in ctx: CGContext, box: CGRect) {
    let scale = max(1, Int(min(box.width / CGFloat(logoW), box.height / CGFloat(logoH))))
    let ox = (box.midX - CGFloat(logoW * scale) / 2).rounded()
    let oy = (box.midY - CGFloat(logoH * scale) / 2).rounded()
    ctx.setShouldAntialias(false)
    for d in dots {
        ctx.setFillColor(d.color)
        let row = maxY - d.y  // 下から数えた行
        ctx.fill(CGRect(x: ox + CGFloat((d.x - minX) * scale), y: oy + CGFloat(row * scale),
                        width: CGFloat(scale), height: CGFloat(scale)))
    }
    ctx.setShouldAntialias(true)
}

/// iPad 版: 白い正方形いっぱいにロゴを置く（角丸は iPadOS が付ける）。App Store の iOS のアイコンは透明を持てないので、アルファなしで書く
if out.pathExtension.lowercased() == "png" {
    let px = 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    // Mac 版の角丸四角の中のロゴと同じ割合（824 の中に 644）
    let side = CGFloat(px) * 644 / 824
    let inset = (CGFloat(px) - side) / 2
    drawLogo(in: ctx, box: CGRect(x: inset, y: inset, width: side, height: side))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: out)
    exit(0)
}
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// macOS のアイコングリッドに合わせ、白い角丸四角の上にロゴを置く
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let s = CGFloat(px) / 1024
    // 1024 中 824 の角丸四角（Big Sur 以降の標準グリッド）
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)
    gc.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 20 * s
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    gc.restoreGraphicsState()
    // ロゴは角丸四角の内側に余白を取って配置
    drawLogo(in: gc.cgContext, box: plate.insetBy(dx: 90 * s, dy: 90 * s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)
