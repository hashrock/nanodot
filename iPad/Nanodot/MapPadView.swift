import NanodotCore
import SwiftUI
import UIKit

/// マップの仮組み（Mac 版のマップウィンドウのキャンバスにあたる）。ストックで選んだセル（マーク範囲）をタイルとして置く。
/// - Apple Pencil: ツール（ペン・消しゴム・塗りつぶし）で置く。ドラッグ中はブラシの大きさ単位でそろえる。近づけるとブラシの影が出る
/// - 指 1 本のドラッグ: 表示を動かす（「指で描く」がオンなら指 1 本でも置き、表示を動かすのは 2 本指）
/// - 指 2 本のドラッグ／ピンチ: 表示を動かす／拡大縮小
/// - 長押し: タイルを拾ってブラシにする。そのままドラッグで範囲を拾う（Mac 版の右クリック・右ドラッグ。メインの長押しと同じ考え方）
/// - 2 本指タップで取り消し、3 本指タップでやり直し（マップの履歴）
/// - Apple Pencil のダブルタップ: ペン ⇄ 消しゴム
final class MapPadView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let state: PadState
    var session: MapSession { state.mapSession }
    var editor: Editor { state.editor }

    private enum Interaction {
        case none
        /// ツールで置いている（start はドラッグ開始のタイル、last は最後に置いた左上）
        case paint(touch: UITouch, start: IntPoint, last: IntPoint?)
        /// 長押しした直後（離せば 1 枚拾う、動かせば範囲）
        case holdPending(start: IntPoint)
        case holdSelect(start: IntPoint, current: IntPoint)
    }

    private var interaction = Interaction.none
    private var viewport = MapViewport(origin: CGPoint(x: 16, y: 16), zoom: 2, cellWidth: 1, cellHeight: 1)
    /// Apple Pencil のホバー位置（ブラシの影を出す）
    private var hoverTile: IntPoint?
    private var panStartOrigin: CGPoint?
    /// 初めて大きさが決まったとき、マップ全体が見えるようにする
    private var needsFit = true
    private var fittedMapID: UUID?

    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let hold = UILongPressGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let threeFingerTap = UITapGestureRecognizer()
    private let hover = UIHoverGestureRecognizer()

    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 16

    init(state: PadState) {
        self.state = state
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        clipsToBounds = true
        isMultipleTouchEnabled = true

        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for g in [pan, pinch, hold, twoFingerTap, threeFingerTap] as [UIGestureRecognizer] {
            g.allowedTouchTypes = direct
            g.delegate = self
            addGestureRecognizer(g)
        }
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        hold.addTarget(self, action: #selector(handleHold(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.addTarget(self, action: #selector(handleUndoTap))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.addTarget(self, action: #selector(handleRedoTap))
        twoFingerTap.require(toFail: threeFingerTap)

        hover.addTarget(self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        state.mapView = self
        updateGestureConfiguration()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateGestureConfiguration() {
        let finger = state.fingerDrawing
        // 指で置くときは、表示を動かすのは 2 本指だけ
        if pan.minimumNumberOfTouches != (finger ? 2 : 1) { pan.minimumNumberOfTouches = finger ? 2 : 1 }
        // メインと同じく、指で置くときは長押しの判定を長くする（置き始めで止めただけで拾わないよう）
        let duration = finger ? MainPadView.fingerDrawingHoldDuration : MainPadView.holdDuration
        if hold.minimumPressDuration != duration { hold.minimumPressDuration = duration }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsFit && bounds.width > 0 { fitToView() }
        setNeedsDisplay()
    }

    // MARK: - 座標

    /// セルの大きさは描くたびにシートから取る
    private var vp: MapViewport {
        var v = viewport
        v.cellWidth = max(1, editor.meta.cellWidth)
        v.cellHeight = max(1, editor.meta.cellHeight)
        return v
    }

    private func tile(at p: CGPoint) -> IntPoint { vp.tile(at: p) }
    private func tile(_ t: UITouch) -> IntPoint { tile(at: t.preciseLocation(in: self)) }

    /// マップ全体が見えるようにする（整数倍に入るなら整数倍）
    func fitToView() {
        guard bounds.width > 0, let m = session.map else {
            needsFit = true
            return
        }
        needsFit = false
        fittedMapID = m.id
        let pad: CGFloat = 24
        let w = CGFloat(m.width * max(1, editor.meta.cellWidth)), h = CGFloat(m.height * max(1, editor.meta.cellHeight))
        var z = min((bounds.width - pad * 2) / w, (bounds.height - pad * 2) / h)
        z = z >= 1 ? floor(z) : z
        z = min(max(z, Self.minZoom), Self.maxZoom)
        viewport.zoom = z
        viewport.origin = CGPoint(x: ((bounds.width - w * z) / 2).rounded(), y: ((bounds.height - h * z) / 2).rounded())
        setNeedsDisplay()
    }

    /// 選ぶマップが変わったら、全体が見えるようにする
    func mapSelectionChanged() {
        if session.selectedMapID != fittedMapID { fitToView() }
    }

    func stepZoom(_ d: Int) {
        let nz = MapDraw.steppedZoom(viewport.zoom, by: d)
        guard nz != viewport.zoom else { return }
        viewport.setZoom(nz, around: CGPoint(x: bounds.midX, y: bounds.midY))
        setNeedsDisplay()
    }

    var zoomPercent: Int { Int((viewport.zoom * 100).rounded()) }

    // MARK: - 描画

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.interpolationQuality = .none
        ctx.setFillColor(UIColor.secondarySystemBackground.cgColor)
        ctx.fill(bounds)
        guard session.map != nil else { return }
        let v = vp
        let sheet = state.sheetImage
        MapDraw.map(ctx, bounds: bounds, viewport: v, session: session, sheet: sheet, showAnnotations: state.showAnnotations)

        switch interaction {
        case .holdSelect(let a, let b):
            let r = IntRect(corner: a, b)
            Draw.outline(ctx, v.tileRect(r.x, r.y, w: r.width, h: r.height))
        case .holdPending(let s):
            Draw.outline(ctx, v.tileRect(s.x, s.y))
        default:
            if let h = hoverTile {
                MapDraw.brushGhost(ctx, viewport: v, session: session, sheet: sheet, at: brushOrigin(for: h))
            }
        }
    }

    /// ドラッグ中はドラッグ開始位置からブラシの大きさ単位でそろえる
    private func brushOrigin(for t: IntPoint) -> IntPoint {
        guard case .paint(_, let start, _) = interaction, session.tool != .fill else { return t }
        return session.brush.alignedOrigin(t, start: start)
    }

    private func setHover(_ t: IntPoint?) {
        guard t != hoverTile else { return }
        hoverTile = t
        setNeedsDisplay()
    }

    // MARK: - 置く（Apple Pencil。「指で描く」なら指も）

    private func canPaint(_ t: UITouch) -> Bool {
        t.type == .pencil || (t.type == .direct && state.fingerDrawing)
    }

    private var activeTouch: UITouch? {
        if case .paint(let t, _, _) = interaction { return t }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard case .none = interaction, let m = session.map, m.layers.indices.contains(session.layer) else { return }
        guard let t = touches.first(where: canPaint) else { return }
        // 2 本目の指が来ているなら置かない（ジェスチャーに任せる）
        if t.type == .direct, (event?.allTouches?.filter { $0.type == .direct }.count ?? 0) > 1 { return }
        let p = tile(t)
        if t.type == .pencil {
            setHover(p)
            state.notePencilUsed()
        }
        session.beginEdit()
        if session.tool == .fill {
            session.apply(at: p)
            // 塗りつぶしは触れた時点で決まる。離すまで paint のままにして、指の長押しで拾わないようにする
            interaction = .paint(touch: t, start: p, last: p)
        } else {
            interaction = .paint(touch: t, start: p, last: nil)
            paint(at: p)
        }
    }

    private func paint(at t: IntPoint) {
        guard case .paint(let touch, let start, let last) = interaction, session.tool != .fill else { return }
        let p = brushOrigin(for: t)
        guard p != last else { return }
        interaction = .paint(touch: touch, start: start, last: p)
        session.apply(at: p)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        // 速く動かしてもタイルが飛ばないよう、間の入力（coalesced）も全部通す
        for ct in event?.coalescedTouches(for: t) ?? [t] {
            let p = tile(ct)
            if case .paint(_, _, let last) = interaction, let last, session.tool != .fill {
                // 前に置いた所から今の所まで、タイル単位でつなぐ
                for q in Raster.line(last, p) { paint(at: q) }
            } else {
                paint(at: p)
            }
        }
        if t.type == .pencil { setHover(tile(t)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        interaction = .none
        if t.type != .pencil { hoverTile = nil }
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 指で置き始めたあと 2 本指の操作に変わったときなど。置きかけは取り消す
        guard let t = activeTouch, touches.contains(t) else { return }
        session.cancelEdit()
        interaction = .none
        hoverTile = nil
        setNeedsDisplay()
    }

    /// Esc: 置きかけ・拾いかけをやめる
    func cancelInteraction() {
        if case .paint = interaction { session.cancelEdit() }
        interaction = .none
        setNeedsDisplay()
    }

    // MARK: - 指の操作

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === pan && other === pinch) || (g === pinch && other === pan)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // ペンで置いている間は指の操作をしない（手のひらが触れても動かないように）
        if let t = activeTouch, t.type == .pencil { return false }
        // 塗りつぶしたあとの指を止めても、長押しで拾わない
        if g === hold, activeTouch != nil { return false }
        return true
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            panStartOrigin = viewport.origin
            if g.numberOfTouches == 1 { state.fingerDragWithoutDrawing() }
        case .changed:
            guard let o = panStartOrigin else { return }
            let t = g.translation(in: self)
            viewport.origin = CGPoint(x: (o.x + t.x).rounded(), y: (o.y + t.y).rounded())
            setNeedsDisplay()
        default:
            panStartOrigin = nil
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        let p = g.location(in: self)
        let nz = min(max(viewport.zoom * g.scale, Self.minZoom), Self.maxZoom)
        g.scale = 1
        viewport.setZoom(nz, around: p)
        // 同時に動いているパンの起点も合わせる（指の下の絵がずれないように）
        if panStartOrigin != nil {
            panStartOrigin = CGPoint(x: viewport.origin.x - pan.translation(in: self).x, y: viewport.origin.y - pan.translation(in: self).y)
        }
        setNeedsDisplay()
    }

    @objc private func handleHold(_ g: UILongPressGestureRecognizer) {
        let p = tile(at: g.location(in: self))
        switch g.state {
        case .began:
            interaction = .holdPending(start: p)
            UISelectionFeedbackGenerator().selectionChanged()
            setNeedsDisplay()
        case .changed:
            switch interaction {
            case .holdPending(let s) where p != s, .holdSelect(let s, _):
                interaction = .holdSelect(start: s, current: p)
                setNeedsDisplay()
            default:
                break
            }
        case .ended:
            switch interaction {
            case .holdPending(let s):
                session.pickTile(at: s)
                state.show(L("タイルを拾いました"))
            case .holdSelect(let a, let b):
                session.pickRange(a, b)
                let br = session.brush
                state.show(L("\(br.width)×\(br.height) のタイルを拾いました"))
            default:
                break
            }
            interaction = .none
            setNeedsDisplay()
        default:
            interaction = .none
            setNeedsDisplay()
        }
    }

    @objc private func handleUndoTap() {
        guard activeTouch == nil else { return }
        session.undo()
        state.show(L("取り消しました"))
    }

    @objc private func handleRedoTap() {
        guard activeTouch == nil else { return }
        session.redo()
        state.show(L("やり直しました"))
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            setHover(tile(at: g.location(in: self)))
        default:
            setHover(nil)
        }
    }

    // MARK: - Apple Pencil のダブルタップ

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        switch UIPencilInteraction.preferredTapAction {
        case .ignore, .showColorPalette:
            // マップには色がないので、パレットの設定のときは何もしない
            return
        default:
            session.tool = session.tool == .eraser ? .pen : .eraser
        }
    }

    #if targetEnvironment(simulator)
    func debugTileRect(_ x: Int, _ y: Int) -> CGRect { vp.tileRect(x, y) }
    func debugTile(at p: CGPoint) -> IntPoint { tile(at: p) }
    #endif
}

struct MapCanvasRepresentable: UIViewRepresentable {
    let state: PadState

    func makeUIView(context: Context) -> MapPadView { MapPadView(state: state) }

    func updateUIView(_ v: MapPadView, context: Context) {
        // 表示に関わる状態を読んでおき、変わったら描き直させる
        let e = state.editor, s = state.mapSession
        _ = (e.meta.maps, e.meta.annotations, e.meta.cellWidth, e.meta.cellHeight, e.meta.mark, e.meta.lupeWidth, e.meta.lupeHeight,
             s.layer, s.tool, s.brushOverride, state.showAnnotations, state.fingerDrawing)
        _ = s.selectedMapID
        v.updateGestureConfiguration()
        v.mapSelectionChanged()
        v.setNeedsDisplay()
    }
}
