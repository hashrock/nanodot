import AppKit
import NanodotCore
import SwiftUI

enum MapTool: String, CaseIterable {
    case pen, eraser, fill

    var label: String {
        switch self {
        case .pen: return "ペン"
        case .eraser: return "消しゴム"
        case .fill: return "塗りつぶし"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil"
        case .eraser: return "eraser"
        case .fill: return "drop.fill"
        }
    }
}

/// マップの仮組みキャンバス。ストックで選んだセル（マーク範囲）をタイルとして置く
final class MapCanvasView: NSView {
    let state: AppState
    var editor: Editor { state.editor }

    private enum Interaction {
        case none
        /// ブラシの大きさ単位で並べて置く（start はドラッグ開始のタイル）
        case paint(start: IntPoint, last: IntPoint?)
        case rightPending(start: IntPoint)
        case rightSelect(start: IntPoint, current: IntPoint)
        case pan(start: CGPoint, startOrigin: CGPoint)
    }

    private var interaction = Interaction.none
    private var zoom: CGFloat = 2
    private var origin = CGPoint(x: 16, y: 16)
    private var hoverTile: IntPoint?
    private var spaceHeld = false
    private var magnifyAccum: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private static let zoomLevels: [CGFloat] = [0.25, 0.5, 1, 2, 3, 4, 6, 8]

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
        super.updateTrackingAreas()
    }

    private var map: TileMapDef? { state.mapIndex.map { editor.meta.maps[$0] } }
    private var tileSize: CGSize { CGSize(width: CGFloat(editor.meta.cellWidth) * zoom, height: CGFloat(editor.meta.cellHeight) * zoom) }

    private func tileRect(_ x: Int, _ y: Int, w: Int = 1, h: Int = 1) -> CGRect {
        let t = tileSize
        return CGRect(x: origin.x + CGFloat(x) * t.width, y: origin.y + CGFloat(y) * t.height, width: t.width * CGFloat(w), height: t.height * CGFloat(h))
    }

    private func tile(_ e: NSEvent) -> IntPoint {
        let p = convert(e.locationInWindow, from: nil), t = tileSize
        return IntPoint(Int(floor((p.x - origin.x) / t.width)), Int(floor((p.y - origin.y) / t.height)))
    }

    // MARK: - 表示

    func stepZoom(_ d: Int, around p: CGPoint? = nil) {
        let p = p ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let i = Self.zoomLevels.firstIndex { $0 >= zoom } ?? Self.zoomLevels.count - 1
        let nz = Self.zoomLevels[min(max(0, i + d), Self.zoomLevels.count - 1)]
        guard nz != zoom else { return }
        let ix = (p.x - origin.x) / zoom, iy = (p.y - origin.y) / zoom
        zoom = nz
        origin = CGPoint(x: (p.x - ix * nz).rounded(), y: (p.y - iy * nz).rounded())
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ctx.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        ctx.fill(bounds)
        guard let map else { return }
        let area = tileRect(0, 0, w: map.width, h: map.height)
        Draw.fillChecker(ctx, area, origin: area.origin, dot: zoom)

        // 見えている範囲のタイルだけ描く
        let t = tileSize
        let x0 = max(0, Int(floor(-origin.x / t.width))), y0 = max(0, Int(floor(-origin.y / t.height)))
        let x1 = min(map.width - 1, Int(ceil((bounds.width - origin.x) / t.width))), y1 = min(map.height - 1, Int(ceil((bounds.height - origin.y) / t.height)))
        guard x0 <= x1, y0 <= y1 else { return }
        for (li, layer) in map.layers.enumerated() where layer.visible {
            for y in y0...y1 {
                for x in x0...x1 {
                    let idx = layer.tiles[y * map.width + x]
                    guard idx >= 0, let img = state.cellImage(idx) else { continue }
                    // 選択中より上のレイヤーは薄く
                    Draw.image(ctx, img, in: CGRect(origin: tileRect(x, y).origin,
                                                    size: CGSize(width: CGFloat(img.width) * zoom, height: CGFloat(img.height) * zoom)),
                               alpha: li > state.mapLayer ? 0.45 : 1)
                }
            }
        }

        // 通れないタイル（表示中のどれかのレイヤーで通行不可）に ×
        if state.showAnnotations {
            let cols = state.sheetColumns
            let blocked = Set(editor.meta.annotations.filter { !$0.passable }.map { SheetMeta.cellIndex(col: $0.col, row: $0.row, columns: cols) })
            if !blocked.isEmpty {
                ctx.saveGState()
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.25, alpha: 0.9))
                ctx.setLineWidth(2)
                for y in y0...y1 {
                    for x in x0...x1 where map.layers.contains(where: { $0.visible && blocked.contains($0.tiles[y * map.width + x]) }) {
                        let r = tileRect(x, y).insetBy(dx: t.width * 0.3, dy: t.height * 0.3)
                        ctx.move(to: CGPoint(x: r.minX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                        ctx.move(to: CGPoint(x: r.maxX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                    }
                }
                ctx.strokePath()
                ctx.restoreGState()
            }
        }

        Draw.grid(ctx, area: area.intersection(bounds), origin: area.origin, stepX: t.width, stepY: t.height,
                  color: CGColor(gray: 0.5, alpha: 0.25))
        Draw.outline(ctx, area.insetBy(dx: -1, dy: -1), color: CGColor(gray: 0.4, alpha: 0.8))

        // カーソル位置にブラシの影、右ドラッグの範囲
        if case .rightSelect(let a, let b) = interaction {
            let r = IntRect(corner: a, b)
            Draw.outline(ctx, tileRect(r.x, r.y, w: r.width, h: r.height))
        } else if let h = hoverTile, !spaceHeld {
            let b = state.mapTool == .fill ? MapBrush.single(state.mapBrush.tiles.first ?? -1) : state.mapBrush
            let p = brushOrigin(for: h)
            if state.mapTool == .pen || state.mapTool == .fill {
                for by in 0..<b.height {
                    for bx in 0..<b.width {
                        guard let img = state.cellImage(b.tiles[by * b.width + bx]) else { continue }
                        Draw.image(ctx, img, in: CGRect(origin: tileRect(p.x + bx, p.y + by).origin,
                                                        size: CGSize(width: CGFloat(img.width) * zoom, height: CGFloat(img.height) * zoom)), alpha: 0.6)
                    }
                }
            }
            Draw.outline(ctx, tileRect(p.x, p.y, w: b.width, h: b.height))
        }
    }

    /// ドラッグ中はドラッグ開始位置からブラシの大きさ単位でそろえる
    private func brushOrigin(for t: IntPoint) -> IntPoint {
        guard case .paint(let start, _) = interaction, state.mapTool != .fill else { return t }
        let b = state.mapBrush
        func align(_ v: Int, _ s: Int, _ n: Int) -> Int { s + Int((Double(v - s) / Double(n)).rounded(.down)) * n }
        return IntPoint(align(t.x, start.x, b.width), align(t.y, start.y, b.height))
    }

    // MARK: - マウス

    private func setHover(_ t: IntPoint?) {
        guard t != hoverTile else { return }
        hoverTile = t
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) { setHover(tile(e)) }
    override func mouseExited(with e: NSEvent) { setHover(nil) }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 49 {
            if !e.isARepeat { spaceHeld = true; NSCursor.openHand.set() }
            return
        }
        super.keyDown(with: e)
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 {
            spaceHeld = false
            NSCursor.arrow.set()
            return
        }
        super.keyUp(with: e)
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if spaceHeld && !CGEventSource.keyState(.combinedSessionState, key: 49) { spaceHeld = false }
        if spaceHeld {
            interaction = .pan(start: convert(e.locationInWindow, from: nil), startOrigin: origin)
            NSCursor.closedHand.set()
            return
        }
        guard let map, map.layers.indices.contains(state.mapLayer) else { return }
        let t = tile(e)
        state.beginMapEdit()
        switch state.mapTool {
        case .fill:
            let v = state.mapBrush.tiles.first ?? -1
            state.mutateMap { $0.fill(state.mapLayer, t.x, t.y, v) }
            interaction = .none
        case .pen, .eraser:
            interaction = .paint(start: t, last: nil)
            paint(at: t)
        }
    }

    private func paint(at t: IntPoint) {
        guard case .paint(let start, let last) = interaction else { return }
        let p = brushOrigin(for: t)
        guard p != last else { return }
        interaction = .paint(start: start, last: p)
        let b = state.mapBrush
        let layer = state.mapLayer
        if state.mapTool == .eraser {
            state.mutateMap { $0.stamp(layer, p.x, p.y, MapBrush(width: b.width, height: b.height, tiles: Array(repeating: -1, count: b.tiles.count)), eraseEmpty: true) }
        } else {
            state.mutateMap { $0.stamp(layer, p.x, p.y, b) }
        }
    }

    override func mouseDragged(with e: NSEvent) {
        if case .pan(let start, let o) = interaction {
            let p = convert(e.locationInWindow, from: nil)
            origin = CGPoint(x: o.x + p.x - start.x, y: o.y + p.y - start.y)
            needsDisplay = true
            return
        }
        let t = tile(e)
        setHover(t)
        paint(at: t)
    }

    override func mouseUp(with e: NSEvent) {
        if case .pan = interaction { NSCursor.openHand.set() }
        interaction = .none
        needsDisplay = true
    }

    /// 右クリックでタイルを拾い、右ドラッグで範囲をブラシにする（メインと同じ操作）
    override func rightMouseDown(with e: NSEvent) {
        interaction = .rightPending(start: tile(e))
    }

    override func rightMouseDragged(with e: NSEvent) {
        let t = tile(e)
        setHover(t)
        switch interaction {
        case .rightPending(let s) where t != s, .rightSelect(let s, _):
            interaction = .rightSelect(start: s, current: t)
            needsDisplay = true
        default:
            break
        }
    }

    override func rightMouseUp(with e: NSEvent) {
        guard let map else { return }
        switch interaction {
        case .rightPending(let s):
            state.mapBrushOverride = .single(map.tile(state.mapLayer, s.x, s.y))
        case .rightSelect(let a, let b):
            let r = IntRect(corner: a, b).intersection(IntRect(x: 0, y: 0, width: map.width, height: map.height))
            if !r.isEmpty { state.mapBrushOverride = map.brush(state.mapLayer, r) }
        default:
            break
        }
        if state.mapTool == .eraser { state.mapTool = .pen }
        interaction = .none
        needsDisplay = true
    }

    /// マウスホイールで拡大縮小、トラックパッドは 2 本指で移動・ピンチで拡大縮小
    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if !e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.shift) && !e.modifierFlags.contains(.option) {
            if e.scrollingDeltaY != 0 { stepZoom(e.scrollingDeltaY > 0 ? 1 : -1, around: p) }
            return
        }
        var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas {
            dx *= 16; dy *= 16
            if e.modifierFlags.contains(.shift) && dx == 0 { swap(&dx, &dy) }
        }
        origin.x += dx
        origin.y += dy
        needsDisplay = true
    }

    override func magnify(with e: NSEvent) {
        magnifyAccum += e.magnification * 4
        if abs(magnifyAccum) >= 1 {
            stepZoom(magnifyAccum > 0 ? 1 : -1, around: convert(e.locationInWindow, from: nil))
            magnifyAccum = 0
        }
    }
}

struct MapCanvasRepresentable: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> MapCanvasView {
        let v = MapCanvasView(state: state)
        state.mapView = v
        return v
    }

    func updateNSView(_ nsView: MapCanvasView, context: Context) {
        let e = state.editor
        _ = (e.meta.maps, e.meta.annotations, e.meta.cellWidth, e.meta.mark, e.meta.lupeWidth, e.meta.lupeHeight,
             state.selectedMapID, state.mapLayer, state.mapTool, state.mapBrushOverride, state.showAnnotations)
        nsView.needsDisplay = true
    }
}

// MARK: - マップウィンドウ

struct MapWindow: View {
    let state: AppState
    @Bindable var editor: Editor

    static let openKey = "mapWindowOpen"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let i = state.mapIndex {
                HStack(spacing: 0) {
                    LayerList(state: state, map: $editor.meta.maps[i])
                        .frame(width: 180)
                    Divider()
                    MapCanvasRepresentable(state: state)
                }
                Divider()
                statusBar(editor.meta.maps[i])
            } else {
                VStack(spacing: 8) {
                    Text("マップがありません").foregroundStyle(.secondary)
                    Button("マップを追加") { addMap() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            UserDefaults.standard.set(true, forKey: Self.openKey)
            if state.mapIndex == nil { state.selectedMapID = editor.meta.maps.first?.id }
        }
        .onDisappear {
            if !AppDelegate.isTerminating { UserDefaults.standard.set(false, forKey: Self.openKey) }
        }
        // ストックでマーク位置を選び直したら、拾ったブラシをやめてマーク範囲のセルに戻す
        .onChange(of: editor.meta.mark) { _, _ in state.mapBrushOverride = nil }
        .onChange(of: editor.meta.lupeWidth) { _, _ in state.mapBrushOverride = nil }
        .onChange(of: editor.meta.lupeHeight) { _, _ in state.mapBrushOverride = nil }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { state.selectedMapID }, set: { state.selectedMapID = $0; state.mapLayer = 0 })) {
                if editor.meta.maps.isEmpty { Text("なし").tag(UUID?.none) }
                ForEach(editor.meta.maps) { m in Text(m.name.isEmpty ? "（無題）" : m.name).tag(UUID?.some(m.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            Button { addMap() } label: { Image(systemName: "plus") }
                .help("マップを追加")
            Button {
                if let i = state.mapIndex {
                    editor.meta.maps.remove(at: i)
                    state.selectedMapID = editor.meta.maps.first?.id
                    state.resetMapHistory()
                }
            } label: { Image(systemName: "minus") }
                .disabled(state.mapIndex == nil)
                .help("マップを削除")

            if let i = state.mapIndex {
                TextField("名前", text: $editor.meta.maps[i].name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                MapSizeFields(state: state, map: editor.meta.maps[i])
            }

            Spacer(minLength: 0)

            Picker("", selection: Binding(get: { state.mapTool }, set: { state.mapTool = $0 })) {
                ForEach(MapTool.allCases, id: \.self) { t in Image(systemName: t.symbol).help(t.label).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle("注釈", isOn: Binding(get: { state.showAnnotations }, set: { state.showAnnotations = $0 }))
                .toggleStyle(.checkbox)
                .help("通行不可のタイルに × を表示（ストックの「注釈」と共通）")
            Button { state.mapView?.stepZoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { state.mapView?.stepZoom(1) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { state.mapUndo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!state.canMapUndo)
                .help("マップの取り消し (⌘Z)")
            Button { state.mapRedo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!state.canMapRedo)
                .help("マップのやり直し (⇧⌘Z)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func statusBar(_ m: TileMapDef) -> some View {
        let b = state.mapBrush
        return HStack(spacing: 12) {
            Text("ブラシ \(b.width)×\(b.height) \(state.mapBrushOverride == nil ? "（マーク範囲）" : "（マップから拾った）")")
            Text("タイル \(editor.meta.cellWidth)×\(editor.meta.cellHeight)")
            Spacer()
            Text("ストックでセルを選んで置く・右クリックで拾う・右ドラッグで範囲を拾う")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
    }

    private func addMap() {
        let m = TileMapDef(name: "マップ \(editor.meta.maps.count + 1)", width: 20, height: 15)
        editor.meta.maps.append(m)
        state.selectedMapID = m.id
        state.mapLayer = 0
    }
}

/// マップの大きさ（確定したときに変える）
private struct MapSizeFields: View {
    let state: AppState
    let map: TileMapDef
    @State private var w = 0
    @State private var h = 0

    var body: some View {
        HStack(spacing: 3) {
            IntField(value: $w, min: 1, max: 512, width: 40)
            Text("×")
            IntField(value: $h, min: 1, max: 512, width: 40)
            Button("変更") {
                state.beginMapEdit()
                state.mutateMap { $0.resize(width: w, height: h) }
            }
            .disabled(w == map.width && h == map.height)
        }
        .onAppear { w = map.width; h = map.height }
        .onChange(of: map.id) { _, _ in w = map.width; h = map.height }
        .onChange(of: map.width) { _, v in w = v }
        .onChange(of: map.height) { _, v in h = v }
    }
}

private struct LayerList: View {
    let state: AppState
    @Binding var map: TileMapDef
    /// 名前を編集中のレイヤー（ダブルクリックで 1 つだけ）
    @State private var editing: Int?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // List（NSTableView）だと名前の入力中のキーを一覧側に取られるので、自前で並べる
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                // 上のレイヤーを上に表示
                ForEach(map.layers.indices.reversed(), id: \.self) { i in
                    HStack(spacing: 6) {
                        Button { map.layers[i].visible.toggle() } label: {
                            Image(systemName: map.layers[i].visible ? "eye" : "eye.slash")
                                .foregroundStyle(map.layers[i].visible ? .primary : .tertiary)
                        }
                        .buttonStyle(.borderless)
                        if editing == i {
                            TextField("", text: $draft)
                                .textFieldStyle(.roundedBorder)
                                .focused($fieldFocused)
                                .onSubmit { commitRename() }
                                .onExitCommand { cancelRename() }
                        } else {
                            Text(map.layers[i].name)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    // 行全体（上下の余白も含む）で受ける。目のボタンはそちらが優先
                    .contentShape(Rectangle())
                    // 1 回目のクリックですぐ選ぶ（ダブルクリック判定を待たない）。2 回目で名前の編集
                    .onTapGesture(count: 2) { if editing != i { beginRename(i) } }
                    .simultaneousGesture(TapGesture().onEnded { if state.mapLayer != i || (editing != nil && editing != i) { select(i) } })
                    .background(state.mapLayer == i ? Color.accentColor.opacity(0.2) : Color.clear)
                }
                }
            }
            // 入力欄からフォーカスが外れたら確定
            .onChange(of: fieldFocused) { _, focused in
                if !focused { commitRename() }
            }
            Divider()
            HStack(spacing: 4) {
                Button { commitRename(); state.beginMapEdit(); map.addLayer(); state.mapLayer = map.layers.count - 1 } label: { Image(systemName: "plus") }
                    .help("レイヤーを追加")
                Button {
                    guard map.layers.count > 1 else { return }
                    commitRename()
                    state.beginMapEdit()
                    map.layers.remove(at: state.mapLayer)
                    state.mapLayer = min(state.mapLayer, map.layers.count - 1)
                } label: { Image(systemName: "minus") }
                    .disabled(map.layers.count <= 1)
                    .help("レイヤーを削除")
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.up") }
                    .disabled(state.mapLayer >= map.layers.count - 1)
                    .help("上へ")
                Button { move(-1) } label: { Image(systemName: "chevron.down") }
                    .disabled(state.mapLayer <= 0)
                    .help("下へ")
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private func select(_ i: Int) {
        commitRename()
        state.mapLayer = i
    }

    private func beginRename(_ i: Int) {
        commitRename()
        state.mapLayer = i
        draft = map.layers[i].name
        editing = i
        // 入力欄ができてからフォーカスを移す
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitRename() {
        guard let i = editing else { return }
        editing = nil
        let name = draft.trimmingCharacters(in: .whitespaces)
        if map.layers.indices.contains(i), !name.isEmpty, name != map.layers[i].name { map.layers[i].name = name }
    }

    private func cancelRename() {
        editing = nil
    }

    private func move(_ d: Int) {
        commitRename()
        let i = state.mapLayer, j = i + d
        guard map.layers.indices.contains(j) else { return }
        state.beginMapEdit()
        map.layers.swapAt(i, j)
        state.mapLayer = j
    }
}
