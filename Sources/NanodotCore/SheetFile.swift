import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum SheetFileError: Error, LocalizedError {
    case unreadable
    case encodeFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: return L("画像を読み込めませんでした")
        case .encodeFailed: return L("画像を書き出せませんでした")
        }
    }
}

/// 書類（PNG）の隣にある、名前が同じで拡張子だけが違うファイル（関連ファイル）の読み書き。
/// App Sandbox では、Info.plist で NSIsRelatedItemType を宣言した拡張子のファイルに限り、
/// NSFileCoordinator と primaryPresentedItemURL を持つ NSFilePresenter を毎回通せば読み書きできる。
/// Sandbox の外でも同じ経路を使う
public enum RelatedFile {
    private final class Presenter: NSObject, NSFilePresenter {
        let primaryPresentedItemURL: URL?
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()

        init(primary: URL, related: URL) {
            primaryPresentedItemURL = primary
            presentedItemURL = related
        }
    }

    private static let lock = NSLock()
    private static var current: Presenter?

    /// いま扱っている関連ファイルのプレゼンター。同じファイルには同じものを使い回し、別のファイルに移ったら登録し直す。
    /// 読み書きのたびに登録・解除すると、解除の直後の書き込みが 0.5 秒ほど待たされる
    private static func presenter(primary: URL, related: URL) -> Presenter {
        lock.lock()
        defer { lock.unlock() }
        if let p = current, p.primaryPresentedItemURL == primary, p.presentedItemURL == related { return p }
        if let old = current { NSFileCoordinator.removeFilePresenter(old) }
        let p = Presenter(primary: primary, related: related)
        NSFileCoordinator.addFilePresenter(p)
        current = p
        return p
    }

    private static func coordinate<T>(_ related: URL, primary: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        let c = NSFileCoordinator(filePresenter: presenter(primary: primary, related: related))
        var cerr: NSError?
        var result: Result<T, Error>?
        if writing {
            c.coordinate(writingItemAt: related, options: [], error: &cerr) { u in result = Result { try body(u) } }
        } else {
            c.coordinate(readingItemAt: related, options: [], error: &cerr) { u in result = Result { try body(u) } }
        }
        if let cerr { throw cerr }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    /// なければ（読めなければ）nil
    public static func read(_ related: URL, primary: URL) -> Data? {
        try? coordinate(related, primary: primary, writing: false) { try Data(contentsOf: $0) }
    }

    public static func write(_ data: Data, to related: URL, primary: URL) throws {
        try coordinate(related, primary: primary, writing: true) { try data.write(to: $0, options: .atomic) }
    }
}

/// PNG ＋サイドカー（`<名前>.nanodot`）の読み書き
public enum SheetFile {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public static let sidecarExtension = "nanodot"

    /// foo.png → foo.nanodot。名前が書類と同じで拡張子が 1 段だけ違うこと（App Sandbox の関連ファイルの条件）
    public static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension(sidecarExtension)
    }

    /// 古い名前のサイドカー: foo.png → foo.nanodot.json（読むだけ。Sandbox では読めない）
    public static func legacySidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("nanodot.json")
    }

    /// 画像と設定を読む。設定は <名前>.nanodot を優先し、なければ古い <名前>.nanodot.json。
    /// どちらも読めなければ（Sandbox で古い名前しかないときも）素の画像として開く
    public static func load(url: URL) throws -> (image: PixelBuffer, meta: SheetMeta?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let img = pixelBuffer(from: cg) else { throw SheetFileError.unreadable }
        let meta = RelatedFile.read(sidecarURL(for: url), primary: url).flatMap(decodeMeta)
            ?? (try? Data(contentsOf: legacySidecarURL(for: url))).flatMap(decodeMeta)
        return (img, meta)
    }

    public static func decodeMeta(_ json: Data) -> SheetMeta? {
        try? JSONDecoder().decode(SheetMeta.self, from: json)
    }

    public static func encodeMeta(_ meta: SheetMeta) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(meta)
    }

    /// PNG と隣のサイドカー（<名前>.nanodot）を書く。古い名前のサイドカーには触らない
    public static func save(_ img: PixelBuffer, meta: SheetMeta, url: URL) throws {
        guard let png = pngData(img) else { throw SheetFileError.encodeFailed }
        let json = try encodeMeta(meta)
        try write(png, to: url)
        try RelatedFile.write(json, to: sidecarURL(for: url), primary: url)
    }

    /// アトミックに書く。Sandbox などで一時ファイルを置けないときは直接書く
    static func write(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .atomic) } catch {
            try data.write(to: url)
        }
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
            case .gif: return L("アニメ GIF")
            case .apng: return "APNG"
            case .pngSequence: return L("連番 PNG")
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
