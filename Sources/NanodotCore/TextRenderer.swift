import CoreGraphics
import CoreText
import Foundation

/// テキストツールの設定
public struct TextSettings: Hashable, Sendable, Codable {
    public var text = "Hello"
    /// フォントの PostScript 名。"system" ならシステムフォント
    public var fontName = "system"
    public var size: Double = 12
    /// 縁がなめらかになる（ドット絵では普通は切る）
    public var antialias = false

    public init() {}
}

/// 文字をドットに描く
public enum TextRenderer {
    /// 選びやすいフォント（PostScript 名, 表示名）
    public static let fonts: [(name: String, label: String)] = [
        ("system", "システム"),
        ("HiraginoSans-W3", "ヒラギノ角ゴ W3"),
        ("HiraginoSans-W6", "ヒラギノ角ゴ W6"),
        ("HiraMaruProN-W4", "ヒラギノ丸ゴ"),
        ("Menlo-Regular", "Menlo"),
        ("Helvetica-Bold", "Helvetica Bold"),
        ("Courier", "Courier"),
    ]

    static func font(_ name: String, size: CGFloat) -> CTFont {
        if name == "system" || name.isEmpty {
            return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        return CTFontCreateWithName(name as CFString, size, nil)
    }

    /// 文字の範囲ぴったりのバッファ（改行可）。不透明度は antialias でなければ 0 か color.a
    public static func render(_ text: String, settings s: TextSettings, color: RGBA) -> PixelBuffer? {
        guard !text.isEmpty else { return nil }
        let font = font(s.fontName, size: CGFloat(max(4, min(s.size, 256))))
        let attrs = [kCTFontAttributeName: font] as CFDictionary
        let lines = text.components(separatedBy: "\n").map { line -> CTLine in
            CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, line as CFString, attrs))
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let lineHeight = ceil(ascent + descent + leading)
        let width = Int(ceil(lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max() ?? 0)) + 2
        let height = Int(lineHeight) * lines.count + 2
        guard width > 2, height > 2, width * height < 4_000_000 else { return nil }

        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setShouldAntialias(s.antialias)
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldSmoothFonts(false)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            for (i, line) in lines.enumerated() {
                // CoreGraphics は左下が原点。1 行目が上に来るように
                ctx.textPosition = CGPoint(x: 1, y: CGFloat(height) - 1 - ascent - CGFloat(i) * lineHeight)
                CTLineDraw(line, ctx)
            }
            return true
        }
        guard ok else { return nil }

        // 白で描いた不透明度を色に置き換え、文字のある範囲に切り詰める
        var px = [RGBA](repeating: .clear, count: width * height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let a = data[(y * width + x) * 4 + 3]
                let alpha: UInt8 = s.antialias ? UInt8(Int(a) * Int(color.a) / 255) : (a >= 128 ? color.a : 0)
                guard alpha > 0 else { continue }
                px[y * width + x] = RGBA(color.r, color.g, color.b, alpha)
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let full = PixelBuffer(width: width, height: height, pixels: px)
        return full.copy(IntRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}
