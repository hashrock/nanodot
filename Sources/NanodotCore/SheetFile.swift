import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum SheetFileError: Error, LocalizedError {
    case unreadable
    case encodeFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "画像を読み込めませんでした"
        case .encodeFailed: return "画像を書き出せませんでした"
        }
    }
}

/// PNG ＋サイドカー JSON の読み書き
public enum SheetFile {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// foo.png → foo.nanodot.json
    public static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("nanodot.json")
    }

    public static func load(url: URL) throws -> (image: PixelBuffer, meta: SheetMeta?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let img = pixelBuffer(from: cg) else { throw SheetFileError.unreadable }
        var meta: SheetMeta?
        if let data = try? Data(contentsOf: sidecarURL(for: url)) {
            meta = try? JSONDecoder().decode(SheetMeta.self, from: data)
        }
        return (img, meta)
    }

    public static func save(_ img: PixelBuffer, meta: SheetMeta, url: URL) throws {
        guard let cg = cgImage(from: img), let data = pngData(cg) else { throw SheetFileError.encodeFailed }
        try data.write(to: url, options: .atomic)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: sidecarURL(for: url), options: .atomic)
    }

    // MARK: - CGImage との変換

    /// 非乗算 RGBA の CGImage を作る
    public static func cgImage(from b: PixelBuffer) -> CGImage? {
        guard b.width > 0, b.height > 0 else { return nil }
        let data = b.pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: b.width, height: b.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: b.width * 4,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public static func pixelBuffer(from cg: CGImage) -> PixelBuffer? {
        rawPixelBuffer(cg) ?? drawnPixelBuffer(cg)
    }

    /// 8bit RGBA / RGBX ならそのままの値を読む（色変換や乗算による誤差を避ける）
    private static func rawPixelBuffer(_ cg: CGImage) -> PixelBuffer? {
        let alpha = cg.alphaInfo
        guard cg.bitsPerComponent == 8, cg.bitsPerPixel == 32,
              cg.colorSpace?.model == .rgb,
              alpha == .last || alpha == .noneSkipLast,
              cg.bitmapInfo.intersection(.byteOrderMask) == [] || cg.bitmapInfo.contains(.byteOrder32Big),
              let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
        let w = cg.width, h = cg.height, bpr = cg.bytesPerRow
        var px = [RGBA](repeating: .clear, count: w * h)
        for y in 0..<h {
            let row = p + y * bpr
            for x in 0..<w {
                let o = row + x * 4
                px[y * w + x] = RGBA(o[0], o[1], o[2], alpha == .last ? o[3] : 255)
            }
        }
        return PixelBuffer(width: w, height: h, pixels: px)
    }

    private static func drawnPixelBuffer(_ cg: CGImage) -> PixelBuffer? {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var px = [RGBA](repeating: .clear, count: w * h)
        for i in 0..<(w * h) {
            let a = buf[i * 4 + 3]
            guard a > 0 else { continue }
            func un(_ v: UInt8) -> UInt8 { UInt8(min(255, (Int(v) * 255 + Int(a) / 2) / Int(a))) }
            px[i] = RGBA(un(buf[i * 4]), un(buf[i * 4 + 1]), un(buf[i * 4 + 2]), a)
        }
        return PixelBuffer(width: w, height: h, pixels: px)
    }

    public static func pngData(_ cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    public static func pngData(_ b: PixelBuffer) -> Data? { cgImage(from: b).flatMap(pngData) }

    public static func pixelBuffer(pngData data: Data) -> PixelBuffer? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return pixelBuffer(from: cg)
    }
}

/// アニメの書き出し
public enum AnimExport {
    public enum Format: String, CaseIterable, Sendable {
        case gif, apng, pngSequence

        public var label: String {
            switch self {
            case .gif: return "アニメ GIF"
            case .apng: return "APNG"
            case .pngSequence: return "連番 PNG"
            }
        }
    }

    /// コマの画像と表示時間
    public static func frames(of anim: AnimDef, in img: PixelBuffer, scale: Int) -> [(PixelBuffer, Int)] {
        anim.resolvedFrames.map { (img.copy(anim.rect(of: $0)).scaled(max(1, scale)), $0.duration) }
    }

    public static func writeGIF(_ frames: [(PixelBuffer, Int)], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw SheetFileError.encodeFailed
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (b, ms) in frames {
            guard let cg = SheetFile.cgImage(from: b) else { throw SheetFileError.encodeFailed }
            let s = Double(ms) / 1000
            CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: s, kCGImagePropertyGIFUnclampedDelayTime: s,
            ]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw SheetFileError.encodeFailed }
    }

    public static func writeAPNG(_ frames: [(PixelBuffer, Int)], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, frames.count, nil) else {
            throw SheetFileError.encodeFailed
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        for (b, ms) in frames {
            guard let cg = SheetFile.cgImage(from: b) else { throw SheetFileError.encodeFailed }
            let s = Double(ms) / 1000
            CGImageDestinationAddImage(dest, cg, [kCGImagePropertyPNGDictionary: [
                kCGImagePropertyAPNGDelayTime: s, kCGImagePropertyAPNGUnclampedDelayTime: s,
            ]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw SheetFileError.encodeFailed }
    }

    /// directory/baseName_000.png, ... を書き出し、書いたファイルを返す
    @discardableResult
    public static func writePNGSequence(_ frames: [(PixelBuffer, Int)], directory: URL, baseName: String) throws -> [URL] {
        let digits = max(3, String(frames.count - 1).count)
        return try frames.enumerated().map { i, f in
            guard let data = SheetFile.pngData(f.0) else { throw SheetFileError.encodeFailed }
            let num = String(i)
            let url = directory.appendingPathComponent("\(baseName)_\(String(repeating: "0", count: max(0, digits - num.count)))\(num).png")
            try data.write(to: url, options: .atomic)
            return url
        }
    }
}
