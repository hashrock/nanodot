import Foundation

/// セルごとの注釈（名前・通行可否・重なり順）
public struct CellAnnotation: Hashable, Sendable, Codable {
    /// シート上のセルの位置（列・行）
    public var col: Int
    public var row: Int
    public var name = ""
    public var passable = true
    /// 重なり順（0 = 通常。大きいほど手前）
    public var z = 0

    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }

    /// 何も設定していない
    public var isDefault: Bool { name.isEmpty && passable && z == 0 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        col = try c.decode(Int.self, forKey: .col)
        row = try c.decode(Int.self, forKey: .row)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        passable = (try? c.decode(Bool.self, forKey: .passable)) ?? true
        z = (try? c.decode(Int.self, forKey: .z)) ?? 0
    }
}

/// マップに置くタイルのかたまり（セル番号の w × h。-1 は空）
public struct MapBrush: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var tiles: [Int]

    public init(width: Int, height: Int, tiles: [Int]) {
        precondition(tiles.count == width * height)
        self.width = width
        self.height = height
        self.tiles = tiles
    }

    public static func single(_ t: Int) -> MapBrush { MapBrush(width: 1, height: 1, tiles: [t]) }
}

public struct MapLayer: Hashable, Sendable, Codable, Identifiable {
    public var id = UUID()
    public var name: String
    public var visible = true
    /// 行優先のタイル（セル番号 = 行 × シートの列数 + 列。-1 は空）
    public var tiles: [Int]

    public init(name: String, count: Int) {
        self.name = name
        tiles = Array(repeating: -1, count: count)
    }

    private enum CodingKeys: String, CodingKey { case name, visible, tiles }
}

/// マップの仮組み
public struct TileMapDef: Hashable, Sendable, Codable, Identifiable {
    public var id = UUID()
    public var name: String
    public private(set) var width: Int
    public private(set) var height: Int
    public var layers: [MapLayer]

    public init(name: String, width: Int, height: Int, layerCount: Int = 2) {
        self.name = name
        self.width = max(1, width)
        self.height = max(1, height)
        layers = (1...max(1, layerCount)).map { MapLayer(name: "レイヤー \($0)", count: max(1, width) * max(1, height)) }
    }

    private enum CodingKeys: String, CodingKey { case name, width, height, layers }

    public func contains(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height }

    public func tile(_ layer: Int, _ x: Int, _ y: Int) -> Int {
        guard layers.indices.contains(layer), contains(x, y) else { return -1 }
        return layers[layer].tiles[y * width + x]
    }

    public mutating func set(_ layer: Int, _ x: Int, _ y: Int, _ t: Int) {
        guard layers.indices.contains(layer), contains(x, y) else { return }
        layers[layer].tiles[y * width + x] = t
    }

    /// ブラシを (x, y) を左上にして置く。eraseEmpty でなければブラシの空は下を残す
    public mutating func stamp(_ layer: Int, _ x: Int, _ y: Int, _ b: MapBrush, eraseEmpty: Bool = false) {
        for by in 0..<b.height {
            for bx in 0..<b.width {
                let t = b.tiles[by * b.width + bx]
                if t < 0 && !eraseEmpty { continue }
                set(layer, x + bx, y + by, t)
            }
        }
    }

    /// 範囲のタイルをブラシとして取り出す
    public func brush(_ layer: Int, _ r: IntRect) -> MapBrush {
        var tiles: [Int] = []
        for y in r.y..<r.maxY {
            for x in r.x..<r.maxX { tiles.append(tile(layer, x, y)) }
        }
        return MapBrush(width: r.width, height: r.height, tiles: tiles)
    }

    /// 4 近傍で同じタイルがつながる範囲を塗る
    public mutating func fill(_ layer: Int, _ x: Int, _ y: Int, _ t: Int) {
        guard layers.indices.contains(layer), contains(x, y) else { return }
        let target = tile(layer, x, y)
        guard target != t else { return }
        var stack = [IntPoint(x, y)]
        while let p = stack.popLast() {
            guard contains(p.x, p.y), tile(layer, p.x, p.y) == target else { continue }
            set(layer, p.x, p.y, t)
            stack += [IntPoint(p.x - 1, p.y), IntPoint(p.x + 1, p.y), IntPoint(p.x, p.y - 1), IntPoint(p.x, p.y + 1)]
        }
    }

    /// 左上を基準に大きさを変える
    public mutating func resize(width w: Int, height h: Int) {
        let w = max(1, min(w, 512)), h = max(1, min(h, 512))
        guard w != width || h != height else { return }
        for i in layers.indices {
            var t = Array(repeating: -1, count: w * h)
            for y in 0..<min(h, height) {
                for x in 0..<min(w, width) { t[y * w + x] = layers[i].tiles[y * width + x] }
            }
            layers[i].tiles = t
        }
        width = w
        height = h
    }

    public mutating func addLayer() {
        layers.append(MapLayer(name: "レイヤー \(layers.count + 1)", count: width * height))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "マップ"
        width = max(1, try c.decode(Int.self, forKey: .width))
        height = max(1, try c.decode(Int.self, forKey: .height))
        let n = width * height
        layers = ((try? c.decode([MapLayer].self, forKey: .layers)) ?? []).map { l in
            var l = l
            if l.tiles.count != n { l.tiles = Array((l.tiles + Array(repeating: -1, count: n)).prefix(n)) }
            return l
        }
        if layers.isEmpty { layers = [MapLayer(name: "レイヤー 1", count: n)] }
    }
}

extension SheetMeta {
    /// セル番号（行 × 列数 + 列）とセル位置の変換
    public static func cellIndex(col: Int, row: Int, columns: Int) -> Int { row * max(1, columns) + col }

    public static func cellPosition(_ index: Int, columns: Int) -> (col: Int, row: Int) {
        (index % max(1, columns), index / max(1, columns))
    }

    public func annotation(col: Int, row: Int) -> CellAnnotation {
        annotations.first { $0.col == col && $0.row == row } ?? CellAnnotation(col: col, row: row)
    }

    /// 設定のない注釈は取り除く
    public mutating func setAnnotation(_ a: CellAnnotation) {
        annotations.removeAll { $0.col == a.col && $0.row == a.row }
        if !a.isDefault {
            annotations.append(a)
            annotations.sort { ($0.row, $0.col) < ($1.row, $1.col) }
        }
    }
}
