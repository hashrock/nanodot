import Foundation
import Observation

public enum Tool: String, CaseIterable, Sendable {
    case pen, eraser, fill, line, rect, ellipse, text, select

    public var displayName: String {
        switch self {
        case .pen: return L("ペン (B)")
        case .eraser: return L("消しゴム (E)")
        case .fill: return L("塗りつぶし (G)")
        case .line: return L("直線 (L)")
        case .rect: return L("矩形 (R)")
        case .ellipse: return L("楕円 (O)")
        case .text: return L("テキスト (T)")
        case .select: return L("選択 (M)")
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
        case .text: return "textformat"
        case .select: return "rectangle.dashed"
        }
    }

    public var isShape: Bool { self == .line || self == .rect || self == .ellipse }
}

@Observable
public final class Editor {
    public private(set) var image: PixelBuffer
    public var meta: SheetMeta {
        // マーク位置・ルーペ・スナップは表示状態なので、変えても未保存扱いにしない
        didSet {
            if !suppressDirty && meta.document != oldValue.document { isDirty = true }
            // 選択範囲はマーク範囲の中に限るので、マーク範囲が変わったら（浮かせた中身は確定して）解除する
            if selection != nil && (meta.mark != oldValue.mark || meta.lupeWidth != oldValue.lupeWidth || meta.lupeHeight != oldValue.lupeHeight) {
                commitSelection()
                selection = nil
            }
        }
    }
    /// 画素が確定するたびに増える（パレット集計などの再計算用）
    public private(set) var revision = 0

    // MARK: ツール状態
    public var tool: Tool = .pen {
        // 選択範囲は選択のツールの間だけ持つ（浮かせた中身は確定する）
        didSet {
            if tool != .select {
                commitSelection()
                selection = nil
            }
        }
    }
    public var shapeFilled = false
    /// ペンと消しゴムの太さ（丸いペン先の直径。奇数なので押した点がちょうど真ん中になる）
    public var penSize = 1
    public static let penSizes = [1, 3, 5, 7, 9, 11, 15, 21, 31, 45, 63]
    public var textSettings = TextSettings()
    public var color = RGBA.black
    /// パレットで押している色（点滅表示）
    public var highlight: RGBA?
    /// スタンプモード
    public var stampActive = false
    public private(set) var clipboard: PixelBuffer?
    /// 選択範囲（シートの座標。メインで選ぶもので、マーク範囲（作業範囲）の中に限る）。
    /// あるときは、マーク範囲の操作（反転・回転・消去・塗りつぶし・シフト）がこの範囲にかかる
    public private(set) var selection: IntRect?

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
    /// 選択範囲の中身を持ち上げて浮かせている間の状態（確定かキャンセルまで）。
    /// base は持ち上げたあと（元の場所を消したあと）の画像、lifted は浮かせている中身
    private struct Floating {
        var base: PixelBuffer
        var lifted: PixelBuffer
        var start: IntRect
        var current: IntRect
        var duplicate: Bool
        var moved = false
        /// 動かさずに反転・回転だけしたときの取り消しの名前
        var label: String?
    }
    @ObservationIgnored private var floating: Floating? {
        didSet { if isFloating != (floating != nil) { isFloating = floating != nil } }
    }
    /// 選択範囲の中身を浮かせている（確定かキャンセルを待っている）
    public private(set) var isFloating = false
    /// ドラッグで動かしている間の、ドラッグを始めたときの範囲
    @ObservationIgnored private var dragOrigin: IntRect?
    @ObservationIgnored private var dragDuplicate = false

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
        floating = nil
        dragOrigin = nil
        selection = nil
        stampActive = false
        updateHistoryFlags()
        isDirty = false
        pixelsChanged()
        revision += 1
    }

    /// 書き出すファイルの名前のもとになる画像のファイル名（未保存なら 無題.png）
    public var imageName: String { fileURL?.lastPathComponent ?? L("無題") + ".png" }

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

    /// 描いている・動かしている途中か（中身を浮かせて確定を待っている間は含めない）
    public var isEditing: Bool { editSnapshot != nil && floating == nil }

    /// 編集を始める。浮かせた中身があれば先に確定する
    public func beginEdit() {
        commitSelection()
        beginEditRaw()
    }

    private func beginEditRaw() {
        if editSnapshot != nil { return }
        editSnapshot = image
        editMark = meta.mark
        editDirty = .zero
    }

    public func endEdit(_ label: String) {
        guard let snap = editSnapshot else { return }
        editSnapshot = nil
        floating = nil
        dragOrigin = nil
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
        let f = floating
        floating = nil
        dragOrigin = nil
        image = snap
        meta.mark = editMark
        if let f { selection = f.start }
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
        commitSelection()
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
        // 浮かせている間の取り消しは、キャンセル（持ち上げる前に戻す）
        if floating != nil { return cancelSelection() }
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
        // 戻した画素と選択範囲が食い違わないよう、取り消し・やり直しでは選択を解除する
        selection = nil
        isDirty = true
        pixelsChanged()
        revision += 1
    }

    // MARK: - 描画

    /// 作業範囲内に点を打つ（beginEdit 〜 endEdit の間で呼ぶ）
    /// clip を省くとマーク範囲（作業範囲）に限る
    public func plot(_ pts: [IntPoint], color c: RGBA, clip: IntRect? = nil) {
        let clip = (clip ?? workRect).intersection(image.bounds)
        var r = IntRect.zero
        let c = c.normalized
        for p in pts where clip.contains(p) && image[p.x, p.y] != c {
            image[p.x, p.y] = c
            r = r.union(p)
        }
        touched(r)
    }

    /// 直径 size の丸いペン先の形（中心からのずれ）。size は奇数を想定し、偶数なら 1 足す
    public static func brushOffsets(size: Int) -> [IntPoint] {
        let r = max(0, size / 2)
        // 半径ちょうどだと上下左右だけ角が出て見えるので、少しふくらませる（3 は十字、5 は角を落とした四角）
        let limit = 2 * r * r + r
        var out: [IntPoint] = []
        for dy in -r...r {
            for dx in -r...r where 2 * (dx * dx + dy * dy) <= limit { out.append(IntPoint(dx, dy)) }
        }
        return out
    }

    /// 点の並びに沿って、直径 size の丸いペン先で塗る
    public func plot(_ pts: [IntPoint], color c: RGBA, size: Int, clip: IntRect? = nil) {
        guard size > 1 else { return plot(pts, color: c, clip: clip) }
        let clip = (clip ?? workRect).intersection(image.bounds)
        let offsets = Editor.brushOffsets(size: size)
        let rad = size / 2
        var r = IntRect.zero
        let c = c.normalized
        for p in pts {
            let b = IntRect(x: p.x - rad, y: p.y - rad, width: rad * 2 + 1, height: rad * 2 + 1).intersection(clip)
            guard !b.isEmpty else { continue }
            for o in offsets {
                let x = p.x + o.x, y = p.y + o.y
                if b.contains(IntPoint(x, y)) && image[x, y] != c { image[x, y] = c }
            }
            r = r.union(b)
        }
        touched(r)
    }

    public func drawShape(_ tool: Tool, from a: IntPoint, to b: IntPoint, filled: Bool, color c: RGBA, clip: IntRect? = nil) {
        edit(tool == .line ? L("直線") : tool == .rect ? L("矩形") : L("楕円")) {
            plot(Self.shapePoints(tool, a, b, filled: filled), color: c, clip: clip)
        }
    }

    /// 文字を描く（透明部分は下を残す）
    @discardableResult
    public func drawText(_ text: String, at p: IntPoint, settings: TextSettings, color c: RGBA, clip: IntRect? = nil) -> IntRect {
        guard let buf = TextRenderer.render(text, settings: settings, color: c) else { return .zero }
        var r = IntRect.zero
        edit(L("テキスト")) {
            r = image.paste(buf, at: p, skipTransparent: true, clip: (clip ?? workRect).intersection(image.bounds))
            touched(r)
        }
        return r
    }

    /// 任意の 1 回の編集を履歴にまとめる（MCP などから使う）
    public func performEdit(_ label: String, _ body: () -> Void) {
        edit(label, body)
    }

    /// 画素をまとめて置く（clip 内だけ）
    public func setPixels(_ px: [(IntPoint, RGBA)], clip: IntRect) {
        var r = IntRect.zero
        let area = clip.intersection(image.bounds)
        for (p, c) in px where area.contains(p) {
            image[p.x, p.y] = c
            r = r.union(p)
        }
        touched(r)
    }

    /// バッファを貼る（edit の中で呼ぶ）
    public func pasteBuffer(_ b: PixelBuffer, at p: IntPoint, skipTransparent: Bool) {
        touched(image.paste(b, at: p, skipTransparent: skipTransparent))
    }

    public static func shapePoints(_ tool: Tool, _ a: IntPoint, _ b: IntPoint, filled: Bool) -> [IntPoint] {
        switch tool {
        case .rect: return Raster.rect(a, b, filled: filled)
        case .ellipse: return Raster.ellipse(a, b, filled: filled)
        default: return Raster.line(a, b)
        }
    }

    public func floodFill(at p: IntPoint, color c: RGBA, clip: IntRect? = nil) {
        let area = (clip ?? workRect).intersection(image.bounds)
        guard area.contains(p), image[p.x, p.y] != c.normalized else { return }
        edit(L("塗りつぶし")) {
            plot(Raster.floodRegion(image, from: p, clip: area), color: c, clip: area)
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
        stamp(along: [p], overwrite: overwrite, clipToWork: clipToWork)
    }

    /// 点の並びに沿ってスタンプを続けて押す（ドラッグでブラシのように描く）。
    /// beginEdit 〜 endEdit の間で呼べば、ドラッグ全体が 1 回の取り消し単位になる
    public func stamp(along pts: [IntPoint], overwrite: Bool, clipToWork: Bool) {
        guard let b = clipboard, !pts.isEmpty else { return }
        edit(L("スタンプ")) {
            var r = IntRect.zero
            for p in pts {
                r = r.union(image.paste(b, at: p, skipTransparent: !overwrite, clip: clipToWork ? workRect : nil))
            }
            touched(r)
        }
    }

    /// マーク範囲の内容を移動先と入れ替え、マーク位置も移動先へ
    public func swapMarkRegion(to dest: IntPoint) {
        let a = markRect.intersection(image.bounds)
        let dest = clampedMark(dest)
        guard !a.isEmpty, dest != meta.mark else { return }
        let b = IntRect(x: dest.x + (a.x - meta.mark.x), y: dest.y + (a.y - meta.mark.y), width: a.width, height: a.height)
        edit(L("入れ替え")) {
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

    /// 90° 回転できるか。選択範囲があればその範囲（回したあとがマーク範囲に収まるとき）、なければマーク範囲（正方形のとき）
    public var canRotate: Bool {
        if let s = selection { return rotatedSelectionRect(s) != nil }
        return meta.lupeWidth == meta.lupeHeight
    }

    /// 選択範囲を回したあとの範囲。中心を保ち、マーク範囲からはみ出すなら中へ寄せる。収まらなければ nil
    private func rotatedSelectionRect(_ s: IntRect) -> IntRect? {
        if s.width == s.height { return s }
        let work = workRect
        guard s.height <= work.width, s.width <= work.height else { return nil }
        var x = s.x + (s.width - s.height) / 2, y = s.y + (s.height - s.width) / 2
        x = min(max(x, work.x), work.maxX - s.height)
        y = min(max(y, work.y), work.maxY - s.width)
        return IntRect(x: x, y: y, width: s.height, height: s.width)
    }

    /// 操作をかける範囲（選択範囲があればそれ、なければマーク範囲）
    public var targetRect: IntRect { selection ?? markRect }

    public func apply(_ op: RegionOp) {
        // 浮かせている中身の反転・回転は、浮かせたまま中身にかける（ほかの操作は確定してから）
        if floating != nil {
            switch op {
            case .flipH, .flipV, .rotateCW, .rotateCCW: return transformFloating(op)
            default: break
            }
        }
        if let s = selection, s.width != s.height {
            switch op {
            case .rotateCW: return rotateSelection(s, clockwise: true)
            case .rotateCCW: return rotateSelection(s, clockwise: false)
            default: break
            }
        }
        let r = targetRect
        let src = image.copy(r)
        let label: String
        let out: PixelBuffer
        switch op {
        case .flipH: out = src.flippedHorizontally(); label = L("左右反転")
        case .flipV: out = src.flippedVertically(); label = L("上下反転")
        case .rotateCW:
            guard canRotate else { return }
            out = src.rotatedClockwise(); label = L("右回転")
        case .rotateCCW:
            guard canRotate else { return }
            out = src.rotatedCounterClockwise(); label = L("左回転")
        case .shift(let dx, let dy): out = src.shifted(dx, dy); label = L("シフト")
        case .clear: out = PixelBuffer(width: r.width, height: r.height); label = L("消去")
        case .fill: out = PixelBuffer(width: r.width, height: r.height, fill: color); label = L("塗りつぶし")
        }
        edit(label) { touched(image.paste(out, at: r.origin)) }
    }

    /// 正方形でない選択範囲を回す（範囲の形が変わるので、元の範囲を消してから置く）
    private func rotateSelection(_ s: IntRect, clockwise: Bool) {
        guard let nr = rotatedSelectionRect(s) else { return }
        let src = image.copy(s)
        let out = clockwise ? src.rotatedClockwise() : src.rotatedCounterClockwise()
        edit(clockwise ? L("右回転") : L("左回転")) {
            var r = image.paste(PixelBuffer(width: s.width, height: s.height), at: s.origin)
            r = r.union(image.paste(out, at: nr.origin))
            touched(r)
        }
        selection = nr
    }

    // MARK: - 選択範囲

    /// 選択範囲を決める（マーク範囲の中に切り詰める。空なら解除）。浮かせた中身があれば先に確定する
    public func setSelection(_ r: IntRect?) {
        commitSelection()
        let c = r?.intersection(workRect)
        selection = (c?.isEmpty ?? true) ? nil : c
    }

    /// 選択範囲の中身を持ち上げて浮かせる（元の場所は透明になる。duplicate なら元を残す）
    private func lift(duplicate: Bool) {
        guard let s = selection, floating == nil, editSnapshot == nil else { return }
        beginEditRaw()
        let lifted = image.copy(s)
        if !duplicate { touched(image.paste(PixelBuffer(width: s.width, height: s.height), at: s.origin)) }
        floating = Floating(base: image, lifted: lifted, start: s, current: s, duplicate: duplicate)
    }

    /// 浮かせた中身を r に置き直す
    private func place(_ out: PixelBuffer, at r: IntRect) {
        guard var f = floating else { return }
        image.paste(f.base.copy(f.current), at: f.current.origin)
        image.paste(out, at: r.origin)
        touched(f.current.union(r))
        f.lifted = out
        f.current = r
        floating = f
        selection = r
    }

    /// ドラッグで動かし始める。中身は動かしたときに持ち上げる（duplicate なら元を残す。すでに浮かせていれば効かない）。
    /// moveSelection で動かし、endMoveSelection でドラッグを終える。中身は commitSelection で確定するまで浮かせたまま
    public func beginMoveSelection(duplicate: Bool = false) {
        guard let s = selection, editSnapshot == nil || floating != nil else { return }
        dragOrigin = s
        dragDuplicate = duplicate
    }

    /// ドラッグを始めた位置からのずれ（ドット）。選択範囲がマーク範囲からはみ出さないように止める
    public func moveSelection(dx: Int, dy: Int) {
        guard let o = dragOrigin else { return }
        if floating == nil {
            guard dx != 0 || dy != 0 else { return }
            lift(duplicate: dragDuplicate)
        }
        guard var f = floating else { return }
        let work = workRect
        let x = min(max(o.x + dx, work.x), work.maxX - o.width)
        let y = min(max(o.y + dy, work.y), work.maxY - o.height)
        let r = IntRect(x: x, y: y, width: o.width, height: o.height)
        guard r != f.current else { return }
        f.moved = true
        floating = f
        place(f.lifted, at: r)
    }

    /// ドラッグを終える（中身は浮かせたまま）
    public func endMoveSelection() {
        dragOrigin = nil
    }

    /// ドラッグをやめて、ドラッグを始めた位置に戻す（それより前に動かした分は浮かせたまま）
    public func cancelMoveSelection() {
        guard let o = dragOrigin else { return }
        if let f = floating, f.current != o { place(f.lifted, at: o) }
        dragOrigin = nil
    }

    /// 浮かせた中身を置いて確定する（1 回の取り消し単位）
    public func commitSelection() {
        guard let f = floating else { return }
        let r = f.current
        endEdit(f.moved ? (f.duplicate ? L("複製") : L("移動")) : (f.label ?? L("移動")))
        selection = r
    }

    /// 浮かせた中身を捨てて、持ち上げる前に戻す（選択範囲も元の位置に）
    public func cancelSelection() {
        guard floating != nil else { return }
        cancelEdit()
    }

    /// 浮かせた中身を反転・回転する（浮かせたまま）
    private func transformFloating(_ op: RegionOp) {
        guard var f = floating else { return }
        var r = f.current
        let out: PixelBuffer
        let label: String
        switch op {
        case .flipH: out = f.lifted.flippedHorizontally(); label = L("左右反転")
        case .flipV: out = f.lifted.flippedVertically(); label = L("上下反転")
        case .rotateCW, .rotateCCW:
            guard let nr = rotatedSelectionRect(f.current) else { return }
            r = nr
            if case .rotateCW = op { out = f.lifted.rotatedClockwise(); label = L("右回転") }
            else { out = f.lifted.rotatedCounterClockwise(); label = L("左回転") }
        default: return
        }
        f.label = f.label == nil || f.label == label ? label : L("変形")
        floating = f
        place(out, at: r)
    }

    /// 選択範囲の中身を動かす（矢印キー）。中身は浮かせたまま
    public func nudgeSelection(dx: Int, dy: Int) {
        guard let s = selection, editSnapshot == nil || floating != nil else { return }
        dragOrigin = s
        dragDuplicate = false
        moveSelection(dx: dx, dy: dy)
        dragOrigin = nil
    }

    /// 範囲をコピーしてから消す
    @discardableResult
    public func cut(_ r: IntRect) -> PixelBuffer? {
        guard let b = copy(r) else { return nil }
        let c = r.intersection(image.bounds)
        edit(L("切り取り")) { touched(image.paste(PixelBuffer(width: c.width, height: c.height), at: c.origin)) }
        return b
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
        edit(L("色の置換")) {
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
        commitSelection()
        let before = image
        let markBefore = meta.mark
        selection = nil
        var out = PixelBuffer(width: width, height: height)
        out.paste(image, at: .zero)
        image = out
        clampMark()
        push(HistoryEntry(label: L("シートサイズ"), rect: nil, before: before, after: out, markBefore: markBefore, markAfter: meta.mark))
        pixelsChanged()
        revision += 1
    }
}
