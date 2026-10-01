import Foundation
import Observation

public enum Tool: String, CaseIterable, Sendable {
    case pen, eraser, fill, line, rect, ellipse

    public var displayName: String {
        switch self {
        case .pen: return "ペン (B)"
        case .eraser: return "消しゴム (E)"
        case .fill: return "塗りつぶし (G)"
        case .line: return "直線 (L)"
        case .rect: return "矩形 (R)"
        case .ellipse: return "楕円 (O)"
        }
    }

    public var symbol: String {
        switch self {
        case .pen: return "pencil"
        case .eraser: return "eraser"
        case .fill: return "drop.fill"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        }
    }

    public var isShape: Bool { self == .line || self == .rect || self == .ellipse }
}

@Observable
public final class Editor {
    public private(set) var image: PixelBuffer
    public var meta: SheetMeta {
        // マーク位置・ルーペ・スナップは表示状態なので、変えても未保存扱いにしない
        didSet { if !suppressDirty && meta.document != oldValue.document { isDirty = true } }
    }
    /// 画素が確定するたびに増える（パレット集計などの再計算用）
    public private(set) var revision = 0

    // MARK: ツール状態
    public var tool: Tool = .pen
    public var shapeFilled = false
    public var color = RGBA.black
    /// パレットで押している色（点滅表示）
    public var highlight: RGBA?
    /// スタンプモード
    public var stampActive = false
    public private(set) var clipboard: PixelBuffer?

    public var fileURL: URL?
    public private(set) var isDirty = false

    // MARK: 履歴
    private struct HistoryEntry {
        var label: String
        /// nil なら画像全体の置き換え
        var rect: IntRect?
        var before: PixelBuffer
        var after: PixelBuffer
        var markBefore: IntPoint
        var markAfter: IntPoint
    }

    @ObservationIgnored private var undoStack: [HistoryEntry] = []
    @ObservationIgnored private var redoStack: [HistoryEntry] = []
    @ObservationIgnored public var maxUndo = 60
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var undoLabel: String?
    public private(set) var redoLabel: String?

    // MARK: 編集中
    @ObservationIgnored private var editSnapshot: PixelBuffer?
    @ObservationIgnored private var editMark = IntPoint.zero
    @ObservationIgnored private var editDirty = IntRect.zero
    @ObservationIgnored private var suppressDirty = false

    // MARK: 表示更新
    /// 画素が変わるたび（編集中も）に増える。表示用キャッシュのキー
    @ObservationIgnored public private(set) var pixelVersion = 0
    @ObservationIgnored public var onPixelsChanged: (() -> Void)?

    public init(width: Int = 256, height: Int = 256) {
        image = PixelBuffer(width: width, height: height)
        meta = SheetMeta()
    }

    // MARK: - ドキュメント

    public func newDocument(width: Int, height: Int, cellWidth: Int, cellHeight: Int) {
        var m = SheetMeta()
        m.cellWidth = max(1, cellWidth)
        m.cellHeight = max(1, cellHeight)
        m.lupeWidth = m.cellWidth
        m.lupeHeight = m.cellHeight
        m.slots = meta.slots
        load(PixelBuffer(width: width, height: height), meta: m, url: nil)
    }

    public func load(_ img: PixelBuffer, meta m: SheetMeta, url: URL?) {
        image = img
        suppressDirty = true
        meta = m
        suppressDirty = false
        clampMark()
        fileURL = url
        undoStack.removeAll()
        redoStack.removeAll()
        editSnapshot = nil
        stampActive = false
        updateHistoryFlags()
        isDirty = false
        pixelsChanged()
        revision += 1
    }

    public func markSaved(url: URL) {
        fileURL = url
        isDirty = false
    }

    // MARK: - マーク位置

    public var markRect: IntRect {
        IntRect(x: meta.mark.x, y: meta.mark.y, width: meta.lupeWidth, height: meta.lupeHeight)
    }

    /// 描画できる範囲（マーク範囲とシートの共通部分）
    public var workRect: IntRect { markRect.intersection(image.bounds) }

    public func setMark(_ p: IntPoint) {
        meta.mark = clampedMark(p)
    }

    /// マーク範囲がなるべくシートからはみ出さないよう制限
    public func clampedMark(_ p: IntPoint) -> IntPoint {
        let mx = max(0, image.width - meta.lupeWidth), my = max(0, image.height - meta.lupeHeight)
        return IntPoint(min(max(0, p.x), mx), min(max(0, p.y), my))
    }

    private func clampMark() { meta.mark = clampedMark(meta.mark) }

    /// スナップ単位で動かす（steps はスナップ単位の個数）
    public func moveMark(dx: Int, dy: Int) {
        setMark(IntPoint(meta.mark.x + dx * meta.snapX, meta.mark.y + dy * meta.snapY))
    }

    public func setLupe(width: Int, height: Int) {
        meta.lupeWidth = max(1, min(width, 1024))
        meta.lupeHeight = max(1, min(height, 1024))
        clampMark()
    }

    /// ルーペサイズを 1/2（拡大）か 2 倍（縮小）にする。anchor のドットが画面上でなるべく動かないようにマーク位置を合わせる
    public func zoomLupe(zoomIn: Bool, anchor: IntPoint) {
        let m = meta
        if zoomIn {
            guard m.lupeWidth > 1 || m.lupeHeight > 1 else { return }
        } else {
            guard m.lupeWidth < image.width || m.lupeHeight < image.height else { return }
        }
        let nw = zoomIn ? max(1, m.lupeWidth / 2) : m.lupeWidth * 2
        let nh = zoomIn ? max(1, m.lupeHeight / 2) : m.lupeHeight * 2
        let fx = min(1, max(0, Double(anchor.x - m.mark.x) / Double(m.lupeWidth)))
        let fy = min(1, max(0, Double(anchor.y - m.mark.y) / Double(m.lupeHeight)))
        var x = anchor.x - Int((fx * Double(nw)).rounded())
        var y = anchor.y - Int((fy * Double(nh)).rounded())
        setLupe(width: nw, height: nh)
        // ルーペがスナップ単位以上ならマーク位置もスナップに合わせる
        func snap(_ v: Int, _ u: Int, _ size: Int) -> Int {
            size >= u ? Int((Double(v) / Double(u)).rounded()) * u : v
        }
        x = snap(x, m.snapX, meta.lupeWidth)
        y = snap(y, m.snapY, meta.lupeHeight)
        setMark(IntPoint(x, y))
    }

    // MARK: - 編集の開始と確定

    public var isEditing: Bool { editSnapshot != nil }

    public func beginEdit() {
        if editSnapshot != nil { return }
        editSnapshot = image
        editMark = meta.mark
        editDirty = .zero
    }

    public func endEdit(_ label: String) {
        guard let snap = editSnapshot else { return }
        editSnapshot = nil
        let r = editDirty.isEmpty ? .zero : image.diffBounds(snap, within: editDirty)
        guard !r.isEmpty || editMark != meta.mark else { return }
        if r.isEmpty {
            // 画素の変化はなくマーク位置だけ動いた（入れ替え先が同じ内容など）
            push(HistoryEntry(label: label, rect: .zero, before: PixelBuffer(width: 0, height: 0),
                              after: PixelBuffer(width: 0, height: 0), markBefore: editMark, markAfter: meta.mark))
        } else {
            push(HistoryEntry(label: label, rect: r, before: snap.copy(r), after: image.copy(r),
                              markBefore: editMark, markAfter: meta.mark))
        }
        revision += 1
    }

    /// 編集を取り消して元に戻す
    public func cancelEdit() {
        guard let snap = editSnapshot else { return }
        editSnapshot = nil
        image = snap
        meta.mark = editMark
        pixelsChanged()
    }

    private func push(_ e: HistoryEntry) {
        undoStack.append(e)
        if undoStack.count > maxUndo { undoStack.removeFirst(undoStack.count - maxUndo) }
        redoStack.removeAll()
        isDirty = true
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoLabel = undoStack.last?.label
        redoLabel = redoStack.last?.label
    }

    /// 1 回で完結する編集
    private func edit(_ label: String, _ body: () -> Void) {
        let nested = editSnapshot != nil
        if !nested { beginEdit() }
        body()
        if !nested { endEdit(label) }
    }

    private func touched(_ r: IntRect) {
        guard !r.isEmpty else { return }
        editDirty = editDirty.union(r)
        pixelsChanged()
    }

    private func pixelsChanged() {
        pixelVersion &+= 1
        onPixelsChanged?()
    }

    // MARK: - 履歴

    public func undo() {
        guard editSnapshot == nil, let e = undoStack.popLast() else { return }
        apply(e, forward: false)
        redoStack.append(e)
        updateHistoryFlags()
    }

    public func redo() {
        guard editSnapshot == nil, let e = redoStack.popLast() else { return }
        apply(e, forward: true)
        undoStack.append(e)
        updateHistoryFlags()
    }

    private func apply(_ e: HistoryEntry, forward: Bool) {
        let buf = forward ? e.after : e.before
        if let r = e.rect {
            if !r.isEmpty { image.paste(buf, at: r.origin) }
        } else {
            image = buf
        }
        meta.mark = forward ? e.markAfter : e.markBefore
        clampMark()
        isDirty = true
        pixelsChanged()
        revision += 1
    }

    // MARK: - 描画

    /// 作業範囲内に点を打つ（beginEdit 〜 endEdit の間で呼ぶ）
    public func plot(_ pts: [IntPoint], color c: RGBA) {
        let clip = workRect
        var r = IntRect.zero
        let c = c.normalized
        for p in pts where clip.contains(p) && image[p.x, p.y] != c {
            image[p.x, p.y] = c
            r = r.union(p)
        }
        touched(r)
    }

    public func drawShape(_ tool: Tool, from a: IntPoint, to b: IntPoint, filled: Bool, color c: RGBA) {
        edit(tool == .line ? "直線" : tool == .rect ? "矩形" : "楕円") {
            plot(Self.shapePoints(tool, a, b, filled: filled), color: c)
        }
    }

    public static func shapePoints(_ tool: Tool, _ a: IntPoint, _ b: IntPoint, filled: Bool) -> [IntPoint] {
        switch tool {
        case .rect: return Raster.rect(a, b, filled: filled)
        case .ellipse: return Raster.ellipse(a, b, filled: filled)
        default: return Raster.line(a, b)
        }
    }

    public func floodFill(at p: IntPoint, color c: RGBA) {
        guard workRect.contains(p), image[p.x, p.y] != c.normalized else { return }
        edit("塗りつぶし") {
            plot(Raster.floodRegion(image, from: p, clip: workRect), color: c)
        }
    }

    public func pick(at p: IntPoint) {
        guard image.contains(p.x, p.y) else { return }
        color = image[p.x, p.y]
    }

    // MARK: - クリップボードとスタンプ

    public func setClipboard(_ b: PixelBuffer) {
        guard b.width > 0, b.height > 0 else { return }
        clipboard = b
    }

    /// 範囲をコピー（シート外は切り詰める）
    @discardableResult
    public func copy(_ r: IntRect) -> PixelBuffer? {
        let c = r.intersection(image.bounds)
        guard !c.isEmpty else { return nil }
        let b = image.copy(c)
        clipboard = b
        return b
    }

    /// クリップボードを貼る。clipToWork ならマーク範囲の外には書かない
    public func stamp(at p: IntPoint, overwrite: Bool, clipToWork: Bool) {
        guard let b = clipboard else { return }
        edit("スタンプ") {
            touched(image.paste(b, at: p, skipTransparent: !overwrite, clip: clipToWork ? workRect : nil))
        }
    }

    /// マーク範囲の内容を移動先と入れ替え、マーク位置も移動先へ
    public func swapMarkRegion(to dest: IntPoint) {
        let a = markRect.intersection(image.bounds)
        let dest = clampedMark(dest)
        guard !a.isEmpty, dest != meta.mark else { return }
        let b = IntRect(x: dest.x + (a.x - meta.mark.x), y: dest.y + (a.y - meta.mark.y), width: a.width, height: a.height)
        edit("入れ替え") {
            let bufA = image.copy(a), bufB = image.copy(b)
            image.paste(bufB, at: a.origin)
            image.paste(bufA, at: b.origin)
            meta.mark = dest
            touched(a.union(b).intersection(image.bounds))
        }
    }

    // MARK: - マーク範囲の操作

    public enum RegionOp {
        case flipH, flipV, rotateCW, rotateCCW, shift(Int, Int), clear, fill
    }

    public var canRotateMark: Bool { meta.lupeWidth == meta.lupeHeight }

    public func apply(_ op: RegionOp) {
        let r = markRect
        let src = image.copy(r)
        let label: String
        let out: PixelBuffer
        switch op {
        case .flipH: out = src.flippedHorizontally(); label = "左右反転"
        case .flipV: out = src.flippedVertically(); label = "上下反転"
        case .rotateCW:
            guard canRotateMark else { return }
            out = src.rotatedClockwise(); label = "右回転"
        case .rotateCCW:
            guard canRotateMark else { return }
            out = src.rotatedCounterClockwise(); label = "左回転"
        case .shift(let dx, let dy): out = src.shifted(dx, dy); label = "シフト"
        case .clear: out = PixelBuffer(width: r.width, height: r.height); label = "消去"
        case .fill: out = PixelBuffer(width: r.width, height: r.height, fill: color); label = "塗りつぶし"
        }
        edit(label) { touched(image.paste(out, at: r.origin)) }
    }

    // MARK: - 色

    @ObservationIgnored private var statsCache: (revision: Int, value: [(color: RGBA, count: Int)])?

    /// 使っている色と画素数（透明を含む）。色相・明度の順
    public func colorStats() -> [(color: RGBA, count: Int)] {
        if let c = statsCache, c.revision == revision { return c.value }
        var counts: [RGBA: Int] = [:]
        for p in image.pixels { counts[p, default: 0] += 1 }
        let v = counts.map { (color: $0.key, count: $0.value) }.sorted { $0.color.sortKey < $1.color.sortKey }
        statsCache = (revision, v)
        return v
    }

    public func replaceColor(_ from: RGBA, with to: RGBA, inMarkOnly: Bool) {
        let area = inMarkOnly ? workRect : image.bounds
        let from = from.normalized, to = to.normalized
        guard from != to, !area.isEmpty else { return }
        edit("色の置換") {
            var r = IntRect.zero
            for y in area.y..<area.maxY {
                for x in area.x..<area.maxX where image[x, y] == from {
                    image[x, y] = to
                    r = r.union(IntPoint(x, y))
                }
            }
            touched(r)
        }
    }

    // MARK: - キャンバス

    /// 左上を基準にシートの大きさを変える
    public func resizeSheet(width: Int, height: Int) {
        guard width > 0, height > 0, width != image.width || height != image.height else { return }
        let before = image
        let markBefore = meta.mark
        var out = PixelBuffer(width: width, height: height)
        out.paste(image, at: .zero)
        image = out
        clampMark()
        push(HistoryEntry(label: "シートサイズ", rect: nil, before: before, after: out, markBefore: markBefore, markAfter: meta.mark))
        pixelsChanged()
        revision += 1
    }
}
