import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum SheetFileError: Error, LocalizedError {
    case unreadable
    case encodeFailed
    case notBundle

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "画像を読み込めませんでした"
        case .encodeFailed: return "画像を書き出せませんでした"
        case .notBundle: return "保存先は .nanodot にしてください"
        }
    }
}

/// ゲームエンジン用データの書き出し先フォルダー。
/// Sandbox では書類の隣に書けないので、ユーザーが一度選んだフォルダーをブックマークで覚える
public enum ExportFolder {
    public static func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        // Sandbox の外や権限のない環境では security-scoped にできないことがあるので、普通のブックマークに落とす
        if let d = try? url.bookmarkData(options: .withSecurityScope) { return d }
        #endif
        return try url.bookmarkData()
    }

    /// ブックマークからフォルダーを得る。stale なら作り直したほうがよい
    public static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        #if os(macOS)
        if let u = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) { return (u, stale) }
        #endif
        guard let u = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        return (u, stale)
    }

    /// フォルダーへのアクセス権を得てから実行する
    public static func access<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}

/// 書類の読み書き。
/// 書類は `<名前>.nanodot` というパッケージ（フォルダー）で、中に `sheet.png`（画像）と `meta.json`（設定）を置く。
/// 古い形式（`<名前>.png` と隣の `<名前>.nanodot.json`）と素の画像は読み込みだけできる
public enum SheetFile {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 書類バンドルの拡張子と UTI
    public static let bundleExtension = "nanodot"
    public static let bundleTypeIdentifier = "dev.hashrock.nanodot.sheet"
    /// バンドルの中のファイル名（書類名によらず固定）
    public static let imageFileName = "sheet.png"
    public static let metaFileName = "meta.json"

    public static func isBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == bundleExtension
    }

    /// 古い形式のサイドカー: foo.png → foo.nanodot.json
    public static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("nanodot.json")
    }

    /// 書類バンドル、または画像（隣に古いサイドカーがあれば設定も）を読む
    public static func load(url: URL) throws -> (image: PixelBuffer, meta: SheetMeta?) {
        if isBundle(url) {
            return (try loadImage(url.appendingPathComponent(imageFileName)), loadMeta(url.appendingPathComponent(metaFileName)))
        }
        let img = try loadImage(url)
        // 古い形式で隣に書いていたゲームエンジン用データは、もう nanodot の管理下にない
        var meta = loadMeta(sidecarURL(for: url))
        meta?.exportedFiles = []
        return (img, meta)
    }

    private static func loadImage(_ url: URL) throws -> PixelBuffer {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let img = pixelBuffer(from: cg) else { throw SheetFileError.unreadable }
        return img
    }

    private static func loadMeta(_ url: URL) -> SheetMeta? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SheetMeta.self, from: $0) }
    }

    /// 素の PNG を書き出す
    public static func exportPNG(_ img: PixelBuffer, to url: URL) throws {
        guard let data = pngData(img) else { throw SheetFileError.encodeFailed }
        try data.write(to: url, options: .atomic)
    }

    /// 書類バンドル（.nanodot）に保存し、オンで書き出し先があればゲームエンジン用データも書く。
    /// ゲームエンジン用データの失敗は保存の失敗にせず、警告の文として返す
    @discardableResult
    public static func save(_ img: PixelBuffer, meta: SheetMeta, url: URL) throws -> [String] {
        guard isBundle(url) else { throw SheetFileError.notBundle }
        guard let png = pngData(img) else { throw SheetFileError.encodeFailed }
        let metaURL = url.appendingPathComponent(metaFileName)
        // 前回この書類から書き出したもの（メモリ上の meta は別の書類から開いたものかもしれないので、ディスクの meta.json を見る）
        let previous = loadMeta(metaURL)

        var meta = meta
        var warnings: [String] = []
        var exportDir: URL?
        if let b = meta.exportBookmark {
            if let r = ExportFolder.resolve(b) {
                exportDir = r.url
                if r.stale, let fresh = try? ExportFolder.bookmark(for: r.url) { meta.exportBookmark = fresh }
            } else if meta.engineExport {
                warnings.append("書き出し先フォルダーが見つかりません。選び直してください")
            }
        }
        // 書類名を書き出すファイルの名前にする（バンドルの中は固定の名前）
        let imageName = url.deletingPathExtension().lastPathComponent + ".png"
        let exporting = meta.engineExport && exportDir != nil
        let files = exporting ? EngineExport.files(imageName: imageName, width: img.width, height: img.height, meta: meta) : []
        meta.exportedFiles = files.map(\.name)

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try png.write(to: url.appendingPathComponent(imageFileName), options: .atomic)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(meta).write(to: metaURL, options: .atomic)

        guard let dir = exportDir else { return warnings }
        ExportFolder.access(dir) {
            for f in (exporting ? [(name: imageName, data: png)] : []) + files {
                // 中身が同じなら書かない（ゲーム側のホットリロードを無駄に起こさない）
                let u = dir.appendingPathComponent(f.name)
                guard (try? Data(contentsOf: u)) != f.data else { continue }
                do { try f.data.write(to: u, options: .atomic) } catch {
                    warnings.append("\(f.name) を書けませんでした: \(error.localizedDescription)")
                }
            }
            // マップの改名・削除や書き出しのオフで作られなくなったものを消す（同じフォルダーへ自分で書いたものだけ。PNG は消さない）
            guard let pb = previous?.exportBookmark, let prevDir = ExportFolder.resolve(pb)?.url,
                  prevDir.standardizedFileURL.path == dir.standardizedFileURL.path else { return }
            let current = Set(meta.exportedFiles)
            for name in previous?.exportedFiles ?? [] where !current.contains(name) && !name.contains("/") {
                let u = dir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: u.path) else { continue }
                do { try FileManager.default.removeItem(at: u) } catch {
                    warnings.append("古い \(name) を消せませんでした: \(error.localizedDescription)")
                }
            }
        }
        return warnings
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
