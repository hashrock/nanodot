import AppKit
import NanodotCore
import SwiftUI

enum Draw {
    /// 透明部分の市松模様（16pt 周期）
    static let checker: CGImage = {
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.86, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        ctx.setFillColor(CGColor(gray: 0.72, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        ctx.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
        return ctx.makeImage()!
    }()

    /// ドット格子に合わせた市松模様。origin はシートの左上、dot は 1 ドットの画面上の大きさ。
    /// 1 マスはドットの 2 のべき乗倍で、画面上 8pt 以上になる最小の大きさ
    static func fillChecker(_ ctx: CGContext, _ rect: CGRect, origin: CGPoint, dot: CGFloat) {
        var cell = max(dot, 0.01)
        while cell < 8 { cell *= 2 }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.interpolationQuality = .none
        ctx.draw(checker, in: CGRect(x: origin.x, y: origin.y, width: cell * 2, height: cell * 2), byTiling: true)
        ctx.restoreGState()
    }

    /// 上下反転した（isFlipped な）ビューに画像を描く
    static func image(_ ctx: CGContext, _ img: CGImage, in rect: CGRect, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.setAlpha(alpha)
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    /// 点滅表示の色（元の色の反転。透明ならマゼンタ）
    static func highlightColor(_ c: RGBA) -> CGColor {
        if c.a == 0 { return CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1) }
        return CGColor(srgbRed: CGFloat(255 - c.r) / 255, green: CGFloat(255 - c.g) / 255, blue: CGFloat(255 - c.b) / 255, alpha: 1)
    }

    /// 1px の白黒二重線で矩形を描く（どんな背景でも見える）
    static func outline(_ ctx: CGContext, _ rect: CGRect, color: CGColor? = nil, dashed: Bool = false) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        if let color {
            if dashed { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
            ctx.setStrokeColor(color)
            ctx.stroke(r)
        } else {
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.9))
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.stroke(r)
        }
        ctx.restoreGState()
    }

    /// 不透明な画素を指定の色に寄せた画像（オニオンスキン用）
    static func tinted(_ b: PixelBuffer, _ tint: RGBA) -> CGImage? {
        var out = b
        for i in out.pixels.indices where out.pixels[i].a > 0 {
            let p = out.pixels[i]
            func mix(_ a: UInt8, _ t: UInt8) -> UInt8 { UInt8((Int(a) + Int(t) * 2) / 3) }
            out.pixels[i] = RGBA(mix(p.r, tint.r), mix(p.g, tint.g), mix(p.b, tint.b), p.a)
        }
        return SheetFile.cgImage(from: out)
    }

    /// シート上の一部分を切り出した画像
    static func crop(_ img: CGImage, _ r: IntRect) -> CGImage? {
        img.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
    }

    /// 指定した色の画素を塗る（点滅表示）
    static func highlight(_ ctx: CGContext, image: PixelBuffer, color: RGBA, area: IntRect, rectFor: (Int, Int) -> CGRect) {
        let a = area.intersection(image.bounds)
        guard !a.isEmpty else { return }
        ctx.setFillColor(highlightColor(color))
        for y in a.y..<a.maxY {
            for x in a.x..<a.maxX where image[x, y] == color { ctx.fill(rectFor(x, y)) }
        }
    }

    /// 格子線
    static func grid(_ ctx: CGContext, area: CGRect, origin: CGPoint, stepX: CGFloat, stepY: CGFloat, color: CGColor) {
        guard stepX >= 3, stepY >= 3 else { return }
        let path = CGMutablePath()
        var x = origin.x + ((area.minX - origin.x) / stepX).rounded(.up) * stepX
        while x < area.maxX {
            let px = x.rounded() + 0.5
            path.move(to: CGPoint(x: px, y: area.minY))
            path.addLine(to: CGPoint(x: px, y: area.maxY))
            x += stepX
        }
        var y = origin.y + ((area.minY - origin.y) / stepY).rounded(.up) * stepY
        while y < area.maxY {
            let py = y.rounded() + 0.5
            path.move(to: CGPoint(x: area.minX, y: py))
            path.addLine(to: CGPoint(x: area.maxX, y: py))
            y += stepY
        }
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(color)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

extension RGBA {
    var swiftUIColor: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func q(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(q(ns.redComponent), q(ns.greenComponent), q(ns.blueComponent), q(ns.alphaComponent))
    }
}

/// 透明を表す市松模様
struct CheckerBackground: View {
    var size: CGFloat = 4

    var body: some View {
        Canvas { ctx, sz in
            ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(Color(white: 0.88)))
            var y: CGFloat = 0
            var row = 0
            while y < sz.height {
                var x: CGFloat = row % 2 == 0 ? 0 : size
                while x < sz.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: size, height: size)), with: .color(Color(white: 0.7)))
                    x += size * 2
                }
                y += size
                row += 1
            }
        }
    }
}
