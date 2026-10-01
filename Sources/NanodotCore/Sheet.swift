import Foundation

/// マーク位置を丸める単位
public enum Snap: Hashable, Sendable, Codable {
    case pixels(Int)
    /// セルの 1/n（n = 1, 2, 4）
    case cell(Int)

    public static let choices: [Snap] = [.cell(1), .cell(2), .cell(4), .pixels(1), .pixels(2), .pixels(4), .pixels(8), .pixels(16), .pixels(32)]

    public var label: String {
        switch self {
        case .pixels(let n): return "\(n) ドット"
        case .cell(let n): return n <= 1 ? "セル" : "セルの 1/\(n)"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            self = .pixels(max(1, n))
        } else if let s = try? c.decode(String.self), s.hasPrefix("cell/"), let n = Int(s.dropFirst(5)) {
            self = .cell(max(1, n))
        } else {
            self = .cell(1)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .pixels(let n): try c.encode(n)
        case .cell(let n): try c.encode(n <= 1 ? "cell" : "cell/\(n)")
        }
    }
}

public struct AnimFrame: Hashable, Sendable, Codable, Identifiable {
    public var id = UUID()
    public var x: Int
    public var y: Int
    /// 表示時間（ミリ秒）
    public var duration: Int

    public init(x: Int, y: Int, duration: Int) {
        self.x = x; self.y = y; self.duration = duration
    }

    private enum CodingKeys: String, CodingKey { case x, y, duration }
}

public struct AnimDef: Hashable, Sendable, Codable, Identifiable {
    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// 起点から列数 × 行数に並んだコマを順に再生
        case grid
        /// 登録したコマを登録順に再生
        case list
    }

    public var id = UUID()
    public var name: String
    public var mode: Mode = .grid
    public var frameWidth: Int
    public var frameHeight: Int
    // grid
    public var originX = 0
    public var originY = 0
    public var columns = 3
    public var rows = 1
    public var count = 3
    public var interval = 150
    // list
    public var frames: [AnimFrame] = []

    public init(name: String, frameWidth: Int, frameHeight: Int) {
        self.name = name
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }

    private enum CodingKeys: String, CodingKey {
        case name, mode, frameWidth, frameHeight, originX, originY, columns, rows, count, interval, frames
    }

    /// 再生するコマの列
    public var resolvedFrames: [AnimFrame] {
        switch mode {
        case .grid:
            let cols = max(1, columns), total = min(max(0, count), cols * max(1, rows))
            return (0..<total).map { i in
                AnimFrame(x: originX + (i % cols) * frameWidth, y: originY + (i / cols) * frameHeight, duration: max(10, interval))
            }
        case .list:
            return frames
        }
    }

    public func rect(of f: AnimFrame) -> IntRect { IntRect(x: f.x, y: f.y, width: frameWidth, height: frameHeight) }
}

/// PNG とは別に保存する設定（サイドカー JSON）
public struct SheetMeta: Equatable, Sendable, Codable {
    public static let slotCount = 64

    public var cellWidth = 32
    public var cellHeight = 32
    public var snap: Snap = .cell(2)
    public var lupeWidth = 32
    public var lupeHeight = 32
    public var mark = IntPoint.zero
    public var showCellGrid = true
    /// 使うサンプルパレットの名前
    public var palette = SamplePalette.all[0].name
    public var slots: [RGBA?] = Array(repeating: nil, count: SheetMeta.slotCount)
    public var anims: [AnimDef] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SheetMeta()
        cellWidth = max(1, (try? c.decode(Int.self, forKey: .cellWidth)) ?? d.cellWidth)
        cellHeight = max(1, (try? c.decode(Int.self, forKey: .cellHeight)) ?? d.cellHeight)
        snap = (try? c.decode(Snap.self, forKey: .snap)) ?? d.snap
        lupeWidth = max(1, (try? c.decode(Int.self, forKey: .lupeWidth)) ?? d.lupeWidth)
        lupeHeight = max(1, (try? c.decode(Int.self, forKey: .lupeHeight)) ?? d.lupeHeight)
        mark = (try? c.decode(IntPoint.self, forKey: .mark)) ?? d.mark
        showCellGrid = (try? c.decode(Bool.self, forKey: .showCellGrid)) ?? d.showCellGrid
        palette = (try? c.decode(String.self, forKey: .palette)) ?? d.palette
        var s = (try? c.decode([RGBA?].self, forKey: .slots)) ?? []
        s = Array(s.prefix(SheetMeta.slotCount))
        s += Array(repeating: nil, count: SheetMeta.slotCount - s.count)
        slots = s
        anims = (try? c.decode([AnimDef].self, forKey: .anims)) ?? []
    }

    /// 表示状態（マーク位置・ルーペ・スナップ）を除いた内容
    public var document: SheetMeta {
        var m = self
        m.mark = .zero
        m.lupeWidth = 0
        m.lupeHeight = 0
        m.snap = .cell(1)
        return m
    }

    public var snapX: Int {
        switch snap {
        case .pixels(let n): return n
        case .cell(let n): return max(1, cellWidth / max(1, n))
        }
    }

    public var snapY: Int {
        switch snap {
        case .pixels(let n): return n
        case .cell(let n): return max(1, cellHeight / max(1, n))
        }
    }

    /// 点をスナップ単位に切り捨て
    public func snapped(_ p: IntPoint) -> IntPoint {
        func f(_ v: Int, _ u: Int) -> Int { Int((Double(v) / Double(u)).rounded(.down)) * u }
        return IntPoint(f(p.x, snapX), f(p.y, snapY))
    }

    /// 移動量をスナップ単位に丸める（四捨五入）
    public func snappedDelta(_ d: IntPoint) -> IntPoint {
        func f(_ v: Int, _ u: Int) -> Int { Int((Double(v) / Double(u)).rounded()) * u }
        return IntPoint(f(d.x, snapX), f(d.y, snapY))
    }
}
