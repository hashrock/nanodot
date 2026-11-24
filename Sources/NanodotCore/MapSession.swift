import CoreGraphics
import Foundation
import Observation

/// マップの仮組みのツール
public enum MapTool: String, CaseIterable, Sendable {
    case pen, eraser, fill

    public var label: String {
        switch self {
        case .pen: return L("ペン")
        case .eraser: return L("消しゴム")
        case .fill: return L("塗りつぶし")
        }
    }

    public var symbol: String {
        switch self {
        case .pen: return "pencil"
        case .eraser: return "eraser"
        case .fill: return "drop.fill"
        }
    }
}

extension MapBrush {
    /// 同じ大きさの空（消しゴム）
    public var erasing: MapBrush { MapBrush(width: width, height: height, tiles: Array(repeating: -1, count: tiles.count)) }

    /// ドラッグ中に置く位置。ドラッグ開始のタイル start から、ブラシの大きさ単位でそろえる
    public func alignedOrigin(_ t: IntPoint, start: IntPoint) -> IntPoint {
        func align(_ v: Int, _ s: Int, _ n: Int) -> Int { s + Int((Double(v - s) / Double(max(1, n))).rounded(.down)) * max(1, n) }
        return IntPoint(align(t.x, start.x, width), align(t.y, start.y, height))
    }
}

extension SheetMeta {
    /// マーク範囲にかかるセルをブラシにしたもの（シートの外のセルは空）
    public func markBrush(imageWidth: Int, imageHeight: Int) -> MapBrush {
        let cw = max(1, cellWidth), ch = max(1, cellHeight)
        let c0 = mark.x / cw, r0 = mark.y / ch
        let c1 = max(c0, (mark.x + lupeWidth - 1) / cw), r1 = max(r0, (mark.y + lupeHeight - 1) / ch)
        let cols = columns(imageWidth: imageWidth), rows = rows(imageHeight: imageHeight)
        var tiles: [Int] = []
        for r in r0...r1 {
            for c in c0...c1 { tiles.append(c < cols && r < rows ? SheetMeta.cellIndex(col: c, row: r, columns: cols) : -1) }
        }
        return MapBrush(width: c1 - c0 + 1, height: r1 - r0 + 1, tiles: tiles)
    }

    /// 通行不可の注釈が付いたセルの番号
    public func blockedCells(columns: Int) -> Set<Int> {
        Set(annotations.filter { !$0.passable }.map { SheetMeta.cellIndex(col: $0.col, row: $0.row, columns: columns) })
    }
}

/// マップの仮組みの編集状態（Mac 版のマップウィンドウと iPad 版のマップで共有）。
/// マップそのものは editor.meta.maps にあり、サイドカーに保存される。ここに持つのは表示・編集の状態と、マップごとの取り消し履歴
@Observable
public final class MapSession {
    @ObservationIgnored public let editor: Editor

    public var selectedMapID: UUID?
    public var layer = 0
    public var tool = MapTool.pen
    /// マップで拾ったブラシ（Mac 版の右クリック・右ドラッグ、iPad 版の長押し）。なければマーク範囲のセル
    public var brushOverride: MapBrush?
    public private(set) var canUndo = false
    public private(set) var canRedo = false

    /// マップを書き換えたとき（表示の更新用）
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private var undoStack: [(id: UUID, map: TileMapDef)] = []
    @ObservationIgnored private var redoStack: [(id: UUID, map: TileMapDef)] = []
    @ObservationIgnored public var maxUndo = 100
    @ObservationIgnored private var cellImageCache: (version: Int, cw: Int, ch: Int, cols: Int, images: [Int: CGImage]) = (-1, 0, 0, 0, [:])

    public init(editor: Editor) {
        self.editor = editor
        selectedMapID = editor.meta.maps.first?.id
    }

    // MARK: - 選択

    public var index: Int? { editor.meta.maps.firstIndex { $0.id == selectedMapID } }
    public var map: TileMapDef? { index.map { editor.meta.maps[$0] } }

    /// シートを開き直した・新規にしたとき: 最初のマップを選び、履歴を捨てる
    public func sheetReplaced() {
        selectedMapID = editor.meta.maps.first?.id
        layer = 0
        brushOverride = nil
        resetHistory()
    }

    /// 選んでいるマップがなくなっていたら（取り消しなどで）、最初のマップを選び直す
    public func ensureSelection() {
        if index == nil { selectedMapID = editor.meta.maps.first?.id }
        if let m = map { layer = min(max(0, layer), m.layers.count - 1) }
    }

    public func select(_ id: UUID?) {
        selectedMapID = id
        layer = 0
    }

    // MARK: - ブラシ

    /// シートの列数（セル番号の計算に使う）
    public var sheetColumns: Int { editor.meta.columns(imageWidth: editor.image.width) }

    public var markBrush: MapBrush { editor.meta.markBrush(imageWidth: editor.image.width, imageHeight: editor.image.height) }
    public var brush: MapBrush { brushOverride ?? markBrush }

    /// タイルを 1 枚拾う（拾ったら消しゴムはペンに戻す）
    public func pickTile(at p: IntPoint) {
        guard let m = map else { return }
        brushOverride = .single(m.tile(layer, p.x, p.y))
        if tool == .eraser { tool = .pen }
    }

    /// 範囲のタイルを拾う
    public func pickRange(_ a: IntPoint, _ b: IntPoint) {
        guard let m = map else { return }
        let r = IntRect(corner: a, b).intersection(IntRect(x: 0, y: 0, width: m.width, height: m.height))
        if !r.isEmpty { brushOverride = m.brush(layer, r) }
        if tool == .eraser { tool = .pen }
    }

    // MARK: - 編集

    /// 取り消し点を記録する（ドラッグ 1 回につき 1 回）
    public func beginEdit() {
        guard let i = index else { return }
        let m = editor.meta.maps[i]
        undoStack.append((m.id, m))
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
        updateHistory()
    }

    public func mutate(_ body: (inout TileMapDef) -> Void) {
        guard let i = index else { return }
        body(&editor.meta.maps[i])
        onChange?()
    }

    /// ツールで (p) に置く（ペン・消しゴムはブラシを左上に、塗りつぶしはブラシの左上のタイルで）
    public func apply(at p: IntPoint) {
        let l = layer, b = brush
        switch tool {
        case .pen: mutate { $0.stamp(l, p.x, p.y, b) }
        case .eraser: mutate { $0.stamp(l, p.x, p.y, b.erasing, eraseEmpty: true) }
        case .fill: mutate { $0.fill(l, p.x, p.y, b.tiles.first ?? -1) }
        }
    }

    /// 描きかけをやめる: 最後の beginEdit の前に戻し、その取り消し点も捨てる（やり直しには積まない）
    public func cancelEdit() {
        guard let e = undoStack.popLast() else { return }
        if let i = editor.meta.maps.firstIndex(where: { $0.id == e.id }) {
            editor.meta.maps[i] = e.map
            onChange?()
        }
        updateHistory()
    }

    public func undo() { stepHistory(undo: true) }
    public func redo() { stepHistory(undo: false) }

    /// 取り消し（undo）・やり直しの 1 歩。配列を inout で渡すと、中で canUndo を更新するときの読み取りと重なるので、向きで分ける
    private func stepHistory(undo: Bool) {
        guard let e = undo ? undoStack.popLast() : redoStack.popLast(),
              let i = editor.meta.maps.firstIndex(where: { $0.id == e.id }) else {
            updateHistory()
            return
        }
        let current = (id: e.id, map: editor.meta.maps[i])
        if undo { redoStack.append(current) } else { undoStack.append(current) }
        editor.meta.maps[i] = e.map
        selectedMapID = e.id
        layer = min(layer, e.map.layers.count - 1)
        updateHistory()
        onChange?()
    }

    private func updateHistory() {
        if canUndo != !undoStack.isEmpty { canUndo = !undoStack.isEmpty }
        if canRedo != !redoStack.isEmpty { canRedo = !redoStack.isEmpty }
    }

    public func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateHistory()
    }

    // MARK: - マップ・レイヤー

    @discardableResult
    public func addMap(width: Int = 20, height: Int = 15) -> TileMapDef {
        let m = TileMapDef(name: L("マップ \(editor.meta.maps.count + 1)"), width: width, height: height)
        editor.meta.maps.append(m)
        select(m.id)
        onChange?()
        return m
    }

    /// 選んでいるマップを消す（取り消しの履歴も捨てる）
    public func removeMap() {
        guard let i = index else { return }
        editor.meta.maps.remove(at: i)
        select(editor.meta.maps.first?.id)
        resetHistory()
        onChange?()
    }

    public func resize(width: Int, height: Int) {
        guard let m = map, width != m.width || height != m.height else { return }
        beginEdit()
        mutate { $0.resize(width: width, height: height) }
    }

    public func addLayer() {
        beginEdit()
        mutate { $0.addLayer() }
        if let m = map { layer = m.layers.count - 1 }
    }

    public func removeLayer() {
        guard let m = map, m.layers.count > 1, m.layers.indices.contains(layer) else { return }
        beginEdit()
        let l = layer
        mutate { $0.layers.remove(at: l) }
        layer = min(l, m.layers.count - 2)
    }

    /// 選んでいるレイヤーを d だけ上（+）・下（-）へ
    public func moveLayer(_ d: Int) {
        let i = layer, j = i + d
        guard let m = map, m.layers.indices.contains(i), m.layers.indices.contains(j) else { return }
        beginEdit()
        mutate { $0.layers.swapAt(i, j) }
        layer = j
    }

    public func toggleLayerVisible(_ i: Int) {
        mutate { if $0.layers.indices.contains(i) { $0.layers[i].visible.toggle() } }
    }

    public func renameLayer(_ i: Int, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard let m = map, m.layers.indices.contains(i), !n.isEmpty, n != m.layers[i].name else { return }
        mutate { $0.layers[i].name = n }
    }

    public func renameMap(_ name: String) {
        guard let m = map, name != m.name else { return }
        mutate { $0.name = name }
    }

    // MARK: - 表示

    /// セル番号の画像（シートの画素・セルの大きさ・列数が変わったら作り直す）。sheet は今のシートの画像
    public func cellImage(_ index: Int, sheet: CGImage?) -> CGImage? {
        guard index >= 0, let sheet else { return nil }
        let cw = editor.meta.cellWidth, ch = editor.meta.cellHeight, cols = sheetColumns
        let c = cellImageCache
        if c.version != editor.pixelVersion || c.cw != cw || c.ch != ch || c.cols != cols {
            cellImageCache = (editor.pixelVersion, cw, ch, cols, [:])
        }
        if let img = cellImageCache.images[index] { return img }
        let (col, row) = SheetMeta.cellPosition(index, columns: cols)
        let r = editor.meta.cellRect(col: col, row: row).intersection(editor.image.bounds)
        guard !r.isEmpty, let img = sheet.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height)) else { return nil }
        cellImageCache.images[index] = img
        return img
    }
}
