// SVG からアプリアイコンを作る
// 使い方: swift scripts/make-icon.swift Resources/AppIcon.svg build/AppIcon.icns       （Mac 版の .icns）
//         swift scripts/make-icon.swift Resources/AppIcon.svg <出力>.png               （iPad 版の 1024×1024。角丸と影なし、不透明）
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let svg = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make-icon.swift <in.svg> <out.icns>\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: args[2])

/// iPad 版: 白い正方形いっぱいにロゴを置く（角丸は iPadOS が付ける）。App Store の iOS のアイコンは透明を持てないので、アルファなしで書く
if out.pathExtension.lowercased() == "png" {
    let px = 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    // Mac 版の角丸四角の中のロゴと同じ割合（824 の中に 644）
    let side = CGFloat(px) * 644 / 824
    let inset = (CGFloat(px) - side) / 2
    svg.draw(in: NSRect(x: inset, y: inset, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
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
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // 1024 中 824 の角丸四角（Big Sur 以降の標準グリッド）
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 20 * s
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // ロゴは角丸四角の内側に余白を取って配置
    let logo = plate.insetBy(dx: 90 * s, dy: 90 * s)
    svg.draw(in: logo, from: .zero, operation: .sourceOver, fraction: 1)
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
