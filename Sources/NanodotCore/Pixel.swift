import Foundation

/// 非乗算アルファの 8bit RGBA。完全透明（a == 0）は RGB を問わず同じ色として扱う。
public struct RGBA: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let clear = RGBA(0, 0, 0, 0)
    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(255, 255, 255)

    public var isTransparent: Bool { a == 0 }
    /// 透明なら RGB を 0 にそろえる
    public var normalized: RGBA { a == 0 ? .clear : self }

    /// "#rrggbbaa"
    public var hex: String { String(format: "#%02x%02x%02x%02x", r, g, b, a) }

    /// "#rrggbb" または "#rrggbbaa"
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff))
        } else {
            self.init(UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff))
        }
    }

    /// 並べ替え用のキー（無彩色 → 色相 12 区分 → 明度）
    public var sortKey: (Int, Int, Int) {
        if a == 0 { return (-2, 0, 0) }
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf)
        let lum = Int((0.299 * rf + 0.587 * gf + 0.114 * bf) * 1000)
        let d = mx - mn
        if d < 0.08 { return (-1, lum, Int(a)) }
        var h: Double
        if mx == rf { h = (gf - bf) / d } else if mx == gf { h = (bf - rf) / d + 2 } else { h = (rf - gf) / d + 4 }
        h = (h * 60).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return (Int(h / 30), lum, Int(a))
    }
}

extension RGBA: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = RGBA(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad color \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

public struct IntPoint: Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    public static let zero = IntPoint(0, 0)
    public static func + (a: IntPoint, b: IntPoint) -> IntPoint { IntPoint(a.x + b.x, a.y + b.y) }
    public static func - (a: IntPoint, b: IntPoint) -> IntPoint { IntPoint(a.x - b.x, a.y - b.y) }
}

public struct IntRect: Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// 2 点を対角とする矩形（両端を含む）
    public init(corner a: IntPoint, _ b: IntPoint) {
        x = min(a.x, b.x); y = min(a.y, b.y)
        width = abs(a.x - b.x) + 1; height = abs(a.y - b.y) + 1
    }

    public static let zero = IntRect(x: 0, y: 0, width: 0, height: 0)

    public var origin: IntPoint { IntPoint(x, y) }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(_ p: IntPoint) -> Bool { p.x >= x && p.y >= y && p.x < maxX && p.y < maxY }

    public func intersection(_ o: IntRect) -> IntRect {
        let nx = max(x, o.x), ny = max(y, o.y)
        let mx = min(maxX, o.maxX), my = min(maxY, o.maxY)
        return mx > nx && my > ny ? IntRect(x: nx, y: ny, width: mx - nx, height: my - ny) : .zero
    }

    public func union(_ o: IntRect) -> IntRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let nx = min(x, o.x), ny = min(y, o.y)
        return IntRect(x: nx, y: ny, width: max(maxX, o.maxX) - nx, height: max(maxY, o.maxY) - ny)
    }

    public func union(_ p: IntPoint) -> IntRect { union(IntRect(x: p.x, y: p.y, width: 1, height: 1)) }

    public func offsetBy(_ dx: Int, _ dy: Int) -> IntRect { IntRect(x: x + dx, y: y + dy, width: width, height: height) }
}

/// RGBA の画素バッファ（左上原点、行優先）
public struct PixelBuffer: Equatable, Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    public var pixels: [RGBA]

    public init(width: Int, height: Int, fill: RGBA = .clear) {
        self.width = max(0, width)
        self.height = max(0, height)
        pixels = [RGBA](repeating: fill.normalized, count: self.width * self.height)
    }

    public init(width: Int, height: Int, pixels: [RGBA]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels.map(\.normalized)
    }

    public var bounds: IntRect { IntRect(x: 0, y: 0, width: width, height: height) }

    public func contains(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height }

    public subscript(x: Int, y: Int) -> RGBA {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue.normalized }
    }

    /// 範囲外は透明
    public func pixel(_ x: Int, _ y: Int) -> RGBA { contains(x, y) ? pixels[y * width + x] : .clear }

    /// 矩形を切り出す（はみ出た部分は透明）
    public func copy(_ r: IntRect) -> PixelBuffer {
        var out = PixelBuffer(width: r.width, height: r.height)
        let src = r.intersection(bounds)
        guard !src.isEmpty else { return out }
        for y in src.y..<src.maxY {
            let so = y * width
            let doff = (y - r.y) * out.width - r.x
            for x in src.x..<src.maxX { out.pixels[doff + x] = pixels[so + x] }
        }
        return out
    }

    /// 別のバッファを貼る。skipTransparent なら透明画素は下を残す。clip の外には書かない。
    /// 戻り値は実際に書いた範囲
    @discardableResult
    public mutating func paste(_ b: PixelBuffer, at p: IntPoint, skipTransparent: Bool = false, clip: IntRect? = nil) -> IntRect {
        var dst = IntRect(x: p.x, y: p.y, width: b.width, height: b.height).intersection(bounds)
        if let clip { dst = dst.intersection(clip) }
        guard !dst.isEmpty else { return .zero }
        for y in dst.y..<dst.maxY {
            let so = (y - p.y) * b.width - p.x
            let doff = y * width
            for x in dst.x..<dst.maxX {
                let c = b.pixels[so + x]
                if skipTransparent && c.a == 0 { continue }
                pixels[doff + x] = c
            }
        }
        return dst
    }

    public mutating func fill(_ r: IntRect, with c: RGBA) {
        let d = r.intersection(bounds)
        guard !d.isEmpty else { return }
        let c = c.normalized
        for y in d.y..<d.maxY {
            for x in d.x..<d.maxX { pixels[y * width + x] = c }
        }
    }

    public func flippedHorizontally() -> PixelBuffer {
        var o = self
        for y in 0..<height {
            for x in 0..<width { o.pixels[y * width + x] = pixels[y * width + (width - 1 - x)] }
        }
        return o
    }

    public func flippedVertically() -> PixelBuffer {
        var o = self
        for y in 0..<height {
            for x in 0..<width { o.pixels[y * width + x] = pixels[(height - 1 - y) * width + x] }
        }
        return o
    }

    /// 時計回りに 90° 回転（幅と高さが入れ替わる）
    public func rotatedClockwise() -> PixelBuffer {
        var o = PixelBuffer(width: height, height: width)
        for y in 0..<height {
            for x in 0..<width { o[height - 1 - y, x] = self[x, y] }
        }
        return o
    }

    public func rotatedCounterClockwise() -> PixelBuffer {
        var o = PixelBuffer(width: height, height: width)
        for y in 0..<height {
            for x in 0..<width { o[y, width - 1 - x] = self[x, y] }
        }
        return o
    }

    /// 回り込みありで平行移動
    public func shifted(_ dx: Int, _ dy: Int) -> PixelBuffer {
        guard width > 0, height > 0 else { return self }
        var o = self
        for y in 0..<height {
            let sy = ((y - dy) % height + height) % height
            for x in 0..<width {
                let sx = ((x - dx) % width + width) % width
                o.pixels[y * width + x] = pixels[sy * width + sx]
            }
        }
        return o
    }

    /// 整数倍に拡大（最近傍）
    public func scaled(_ s: Int) -> PixelBuffer {
        guard s > 1 else { return self }
        var o = PixelBuffer(width: width * s, height: height * s)
        for y in 0..<o.height {
            for x in 0..<o.width { o.pixels[y * o.width + x] = pixels[(y / s) * width + x / s] }
        }
        return o
    }

    /// 2 つのバッファで異なる画素を含む最小の矩形（同じ大きさであること）
    public func diffBounds(_ o: PixelBuffer, within r: IntRect? = nil) -> IntRect {
        precondition(width == o.width && height == o.height)
        let area = (r ?? bounds).intersection(bounds)
        guard !area.isEmpty else { return .zero }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in area.y..<area.maxY {
            let off = y * width
            for x in area.x..<area.maxX where pixels[off + x] != o.pixels[off + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        return maxX < 0 ? .zero : IntRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
