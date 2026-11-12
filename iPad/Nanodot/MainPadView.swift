import NanodotCore
import SwiftUI
import UIKit

/// メイン: マーク範囲（ルーペ）を整数倍に拡大して描く。
/// - Apple Pencil: ツールで描く。ダブルタップでペンと消しゴムを切り替える。近づける（ホバー）と、描くドットに枠が出る
/// - 指 1 本・2 本のドラッグ: マーク位置を動かす（セルの 1/8 単位。Mac 版のスペース + ドラッグ）
/// - ピンチ: ルーペサイズを 1/2・2 倍にする（Mac 版のホイール）
/// - 長押し: スポイト。長押しのままドラッグすると範囲をコピーしてスタンプモードへ（Mac 版の右クリック・右ドラッグ）
/// - スポイトのツール: Apple Pencil か指 1 本で触れた所の色を拾う（ドラッグ中は追従し、離した所で決めて直前のツールに戻る）
/// - 2 本指タップで取り消し、3 本指タップでやり直し
/// - 「指で描く」がオンなら、指 1 本でも描く（マーク位置を動かすのは 2 本指）
final class MainPadView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let state: PadState
    var editor: Editor { state.editor }

    private enum Interaction {
        case none
        case stroke(touch: UITouch, last: IntPoint, color: RGBA)
        case shape(touch: UITouch, start: IntPoint, current: IntPoint)
        /// スポイトで触れている間（original は拾う前の色。シートの外で離したり取り消されたりしたら戻す）
        case pick(touch: UITouch, original: RGBA)
        /// 長押しした直後（離せばスポイト、動かせば範囲コピー）
        case holdPending(start: IntPoint)
        case holdSelect(start: IntPoint, current: IntPoint)
    }

    private var interaction = Interaction.none
    /// Apple Pencil のホバー位置（描くドットに枠を出す）
    private var hoverDot: IntPoint?
    private var panStartMark: IntPoint?
    private var pinchAccum: CGFloat = 0

    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let hold = UILongPressGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let threeFingerTap = UITapGestureRecognizer()
    private let hover = UIHoverGestureRecognizer()

    init(state: PadState) {
        self.state = state
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        clipsToBounds = true
        isMultipleTouchEnabled = true

        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for g in [pan, pinch, hold, tap, twoFingerTap, threeFingerTap] as [UIGestureRecognizer] {
            g.allowedTouchTypes = direct
            g.delegate = self
            addGestureRecognizer(g)
        }
        pan.addTarget(self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        hold.minimumPressDuration = 0.35
        hold.addTarget(self, action: #selector(handleHold(_:)))
        tap.addTarget(self, action: #selector(handleTap(_:)))
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

        state.mainView = self
        updateGestureConfiguration()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateGestureConfiguration() {
        // 指で描くときは、マーク位置を動かすのは 2 本指だけ
        pan.minimumNumberOfTouches = state.fingerDrawing ? 2 : 1
        tap.isEnabled = !state.fingerDrawing
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    // MARK: - 座標

    private let padding: CGFloat = 16

    /// ルーペ範囲が収まる倍率（1 以上なら整数）。整数にするので、どのドットも画面上で同じ大きさになり、ペン先とドットがずれない
    var zoom: CGFloat {
        let m = editor.meta
        let z = min((bounds.width - padding * 2) / CGFloat(m.lupeWidth), (bounds.height - padding * 2) / CGFloat(m.lupeHeight))
        return z >= 1 ? floor(z) : max(z, 0.05)
    }

    /// マーク位置（左上）の画面座標。物理ピクセルの境界にそろえる
    private var markOrigin: CGPoint {
        let m = editor.meta, z = zoom
        let s = max(1, traitCollection.displayScale)
        return CGPoint(x: (((bounds.width - CGFloat(m.lupeWidth) * z) / 2) * s).rounded() / s,
                       y: (((bounds.height - CGFloat(m.lupeHeight) * z) / 2) * s).rounded() / s)
    }

    private func screenRect(_ r: IntRect) -> CGRect {
        let o = markOrigin, z = zoom, mk = editor.meta.mark
        return CGRect(x: o.x + CGFloat(r.x - mk.x) * z, y: o.y + CGFloat(r.y - mk.y) * z,
                      width: CGFloat(r.width) * z, height: CGFloat(r.height) * z)
    }

    private func dot(at p: CGPoint) -> IntPoint {
        let o = markOrigin, z = zoom, mk = editor.meta.mark
        return IntPoint(mk.x + Int(floor((p.x - o.x) / z)), mk.y + Int(floor((p.y - o.y) / z)))
    }

    #if targetEnvironment(simulator)
    func debugScreenRect(_ r: IntRect) -> CGRect { screenRect(r) }
    func debugDot(at p: CGPoint) -> IntPoint { dot(at: p) }
    #endif

    /// ペン先の位置は preciseLocation（表示の解像度より細かい）で取る
    private func dot(_ t: UITouch) -> IntPoint { dot(at: t.preciseLocation(in: self)) }

    // MARK: - 描画

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.interpolationQuality = .none
        ctx.setFillColor(UIColor.secondarySystemBackground.cgColor)
        ctx.fill(bounds)

        let img = editor.image
        let sheet = screenRect(img.bounds)
        let visibleSheet = sheet.intersection(bounds)
        if !visibleSheet.isNull {
            Draw.fillChecker(ctx, visibleSheet, origin: sheet.origin, dot: zoom)
            drawOnionSkin(ctx)
            if let cg = state.sheetImage { Draw.image(ctx, cg, in: sheet) }
        }

        let z = zoom
        let lo = dot(at: .zero), hi = dot(at: CGPoint(x: bounds.maxX, y: bounds.maxY))
        let visibleDots = IntRect(corner: lo, hi)

        if let h = editor.highlight, state.blinkOn {
            Draw.highlight(ctx, image: img, color: h, area: visibleDots) { x, y in self.screenRect(IntRect(x: x, y: y, width: 1, height: 1)) }
        }

        // 図形のプレビュー
        if case .shape(_, let a, let b) = interaction {
            let c = editor.color
            ctx.setFillColor(c.a == 0 ? CGColor(gray: 1, alpha: 0.6) : Draw.cgColor(c))
            let work = editor.workRect
            for p in Editor.shapePoints(editor.tool, a, b, filled: editor.shapeFilled) where work.contains(p) {
                ctx.fill(screenRect(IntRect(x: p.x, y: p.y, width: 1, height: 1)))
            }
        }

        // グリッド
        if !visibleSheet.isNull {
            if z >= 8 {
                Draw.grid(ctx, area: visibleSheet, origin: sheet.origin, stepX: z, stepY: z, color: CGColor(gray: 0.5, alpha: 0.22))
            }
            let m = editor.meta
            if m.showCellGrid {
                Draw.grid(ctx, area: visibleSheet, origin: sheet.origin, stepX: CGFloat(m.cellWidth) * z, stepY: CGFloat(m.cellHeight) * z,
                          color: CGColor(srgbRed: 0.2, green: 0.55, blue: 1, alpha: 0.6))
            }
        }

        // マーク範囲の外を暗く
        let mark = screenRect(editor.markRect)
        ctx.saveGState()
        ctx.addRect(bounds)
        ctx.addRect(mark)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
        Draw.outline(ctx, mark.insetBy(dx: -1, dy: -1), color: tintColor.cgColor)

        // 長押しドラッグの範囲
        if case .holdSelect(let a, let b) = interaction {
            Draw.outline(ctx, screenRect(IntRect(corner: a, b)))
        }

        // スタンプの影、またはペン先のドット
        if let h = hoverDot {
            if editor.stampActive, let clip = editor.clipboard {
                let r = screenRect(IntRect(x: h.x, y: h.y, width: clip.width, height: clip.height))
                if let cg = SheetFile.cgImage(from: clip) { Draw.image(ctx, cg, in: r, alpha: 0.75) }
                Draw.outline(ctx, r)
            } else if z >= 4 {
                Draw.outline(ctx, screenRect(IntRect(x: h.x, y: h.y, width: 1, height: 1)))
            }
        } else if editor.stampActive, let clip = editor.clipboard {
            // ホバーできないときは、マーク位置にスタンプの大きさを点線で示す
            let mk = editor.meta.mark
            Draw.outline(ctx, screenRect(IntRect(x: mk.x, y: mk.y, width: clip.width, height: clip.height)),
                         color: CGColor(gray: 1, alpha: 0.6), dashed: true)
        }
    }

    /// アニメのパネルを出していて、マーク位置がアニメのコマと同じなら、前のコマを赤・次のコマを青で下に重ねる
    private func drawOnionSkin(_ ctx: CGContext) {
        guard state.animPanelVisible, state.onionSkin,
              let anim = editor.meta.anims.first(where: { $0.id == state.selectedAnimID }) else { return }
        let frames = anim.resolvedFrames, n = frames.count
        let mk = editor.meta.mark
        guard n > 1, let i = frames.firstIndex(where: { $0.x == mk.x && $0.y == mk.y }) else { return }
        var shown: [(AnimFrame, RGBA)] = [(frames[(i - 1 + n) % n], RGBA(255, 60, 70))]
        if n > 2 { shown.append((frames[(i + 1) % n], RGBA(40, 120, 255))) }
        for (f, tint) in shown {
            let buf = editor.image.copy(anim.rect(of: f))
            guard let img = Draw.tinted(buf, tint) else { continue }
            Draw.image(ctx, img, in: screenRect(IntRect(x: mk.x, y: mk.y, width: buf.width, height: buf.height)), alpha: 0.4)
        }
    }

    private func setHover(_ d: IntPoint?) {
        guard d != hoverDot else { return }
        hoverDot = d
        setNeedsDisplay()
    }

    // MARK: - 描く（Apple Pencil。「指で描く」なら指も）

    private func canDraw(_ t: UITouch) -> Bool {
        t.type == .pencil || (t.type == .direct && state.fingerDrawing)
    }

    private var activeTouch: UITouch? {
        switch interaction {
        case .stroke(let t, _, _), .shape(let t, _, _), .pick(let t, _): return t
        default: return nil
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard case .none = interaction else { return }
        if state.eyedropperActive {
            beginPick(touches, event)
            return
        }
        guard let t = touches.first(where: canDraw) else { return }
        // 2 本目の指が来ているなら描かない（ジェスチャーに任せる）
        if t.type == .direct, (event?.allTouches?.filter { $0.type == .direct }.count ?? 0) > 1 { return }
        let d = dot(t)
        if t.type == .pencil { setHover(d) }
        if editor.stampActive {
            editor.stamp(at: d, overwrite: !state.stampSkipTransparent, clipToWork: true)
            return
        }
        switch editor.tool {
        case .pen, .eraser:
            let c = editor.tool == .eraser ? RGBA.clear : editor.color
            editor.beginEdit()
            editor.plot([d], color: c)
            interaction = .stroke(touch: t, last: d, color: c)
        case .fill:
            editor.floodFill(at: d, color: editor.color)
        case .line, .rect, .ellipse:
            interaction = .shape(touch: t, start: d, current: d)
            setNeedsDisplay()
        case .text:
            // テキストツールは iPad 版にはない（キーボードでも選べない）
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        switch interaction {
        case .pick:
            let d = dot(t)
            editor.pick(at: d)
            if t.type == .pencil { setHover(d) }
        case .stroke(_, var last, let c):
            // 速く動かしても点が飛ばないよう、間の入力（coalesced）も全部つなぐ
            for ct in event?.coalescedTouches(for: t) ?? [t] {
                let d = dot(ct)
                guard d != last else { continue }
                editor.plot(Raster.line(last, d), color: c)
                last = d
            }
            interaction = .stroke(touch: t, last: last, color: c)
            if t.type == .pencil { setHover(last) }
        case .shape(_, let a, _):
            let d = dot(t)
            let shift = event?.modifierFlags.contains(.shift) ?? false
            let b = shift ? Raster.constrain(a, d, diagonalSnap: editor.tool == .line) : d
            interaction = .shape(touch: t, start: a, current: b)
            if t.type == .pencil { hoverDot = d }
            setNeedsDisplay()
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        switch interaction {
        case .stroke:
            editor.endEdit(editor.tool == .eraser ? L("消しゴム") : L("ペン"))
        case .shape(_, let a, let b):
            editor.drawShape(editor.tool, from: a, to: b, filled: editor.shapeFilled, color: editor.color)
        case .pick(_, let original):
            if !state.finishEyedropper(at: dot(t)) { editor.color = original }
        default:
            break
        }
        interaction = .none
        if t.type != .pencil { hoverDot = nil }
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 指で描き始めたあと 2 本指の操作に変わったときなど。描きかけは取り消す
        guard let t = activeTouch, touches.contains(t) else { return }
        if case .stroke = interaction { editor.cancelEdit() }
        cancelPick()
        interaction = .none
        setNeedsDisplay()
    }

    // MARK: - スポイト

    private func beginPick(_ touches: Set<UITouch>, _ event: UIEvent?) {
        guard let t = touches.first(where: { $0.type == .pencil || $0.type == .direct }) else { return }
        if t.type == .direct, (event?.allTouches?.filter { $0.type == .direct }.count ?? 0) > 1 { return }
        let d = dot(t)
        if t.type == .pencil { setHover(d) }
        interaction = .pick(touch: t, original: editor.color)
        editor.pick(at: d)
        setNeedsDisplay()
    }

    /// 拾いかけを取り消す（指のドラッグがマーク移動に変わったときなど）。
    /// 指のタップは handleTap が決めるので、そちらで先に決まっていれば色は戻さない
    private func cancelPick() {
        guard case .pick(_, let original) = interaction, state.eyedropperActive else { return }
        editor.color = original
    }

    // MARK: - 指の操作

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // 2 本指のドラッグとピンチは同時に効かせる
        (g === pan && other === pinch) || (g === pinch && other === pan)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // ペンで描いている間は指の操作をしない（手のひらが触れても動かないように）
        if let t = activeTouch, t.type == .pencil { return false }
        if g === pan || g === pinch || g === hold { return !editor.isEditing || activeTouch?.type == .direct }
        return true
    }

    /// パンの単位（セルの 1/8）
    private var panUnit: (x: Int, y: Int) {
        (max(1, editor.meta.cellWidth / 8), max(1, editor.meta.cellHeight / 8))
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            panStartMark = editor.meta.mark
        case .changed:
            guard let startMark = panStartMark else { return }
            let t = g.translation(in: self)
            let (ux, uy) = panUnit
            let z = zoom
            // 指の動きと絵の動きをそろえる（指を右へ動かすと絵も右へ = マーク位置は左へ）
            let dx = Int((-t.x / z / CGFloat(ux)).rounded()) * ux
            let dy = Int((-t.y / z / CGFloat(uy)).rounded()) * uy
            let m = IntPoint(startMark.x + dx, startMark.y + dy)
            if editor.clampedMark(m) != editor.meta.mark {
                editor.setMark(m)
                state.stockView?.scrollMarkToVisible()
                state.requestDisplay()
            }
        default:
            panStartMark = nil
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchAccum = 0
        case .changed:
            // 倍率が 2 倍・1/2 になるごとにルーペサイズを 1 段変える
            pinchAccum += log2(g.scale)
            g.scale = 1
            guard abs(pinchAccum) >= 0.6, !editor.isEditing else { return }
            let zoomIn = pinchAccum > 0
            pinchAccum = 0
            editor.zoomLupe(zoomIn: zoomIn, anchor: dot(at: g.location(in: self)))
            panStartMark = editor.meta.mark
            pan.setTranslation(.zero, in: self)
            state.stockView?.scrollMarkToVisible()
            state.requestDisplay()
        default:
            pinchAccum = 0
        }
    }

    @objc private func handleHold(_ g: UILongPressGestureRecognizer) {
        let d = dot(at: g.location(in: self))
        switch g.state {
        case .began:
            if editor.stampActive {
                // スタンプモード中の長押しは、Mac 版の右クリックと同じくモードを抜ける
                editor.stampActive = false
                interaction = .none
                g.isEnabled = false
                g.isEnabled = true
                setNeedsDisplay()
                return
            }
            cancelPick()
            interaction = .holdPending(start: d)
            editor.pick(at: d)
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            switch interaction {
            case .holdPending(let s):
                if max(abs(d.x - s.x), abs(d.y - s.y)) >= max(1, state.dragThreshold) {
                    interaction = .holdSelect(start: s, current: d)
                    setNeedsDisplay()
                } else {
                    editor.pick(at: d)
                }
            case .holdSelect(let s, _):
                interaction = .holdSelect(start: s, current: d)
                setNeedsDisplay()
            default:
                break
            }
        case .ended:
            if case .holdSelect(let a, let b) = interaction, let buf = editor.copy(IntRect(corner: a, b)) {
                state.setClipboard(buf)
                state.eyedropperActive = false
                editor.stampActive = true
            } else if case .holdPending(let s) = interaction, state.eyedropperActive {
                // スポイトのツールのまま長押しで拾ったときも、直前のツールに戻る
                state.finishEyedropper(at: s)
            }
            interaction = .none
            setNeedsDisplay()
        default:
            interaction = .none
            setNeedsDisplay()
        }
    }

    /// 指のタップ: スポイトなら拾う。スタンプモードなら押す
    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        if state.eyedropperActive {
            state.finishEyedropper(at: dot(at: g.location(in: self)))
            return
        }
        guard editor.stampActive else { return }
        editor.stamp(at: dot(at: g.location(in: self)), overwrite: !state.stampSkipTransparent, clipToWork: true)
    }

    @objc private func handleUndoTap() {
        guard !editor.isEditing else { return }
        editor.undo()
        state.show(L("取り消しました"))
    }

    @objc private func handleRedoTap() {
        guard !editor.isEditing else { return }
        editor.redo()
        state.show(L("やり直しました"))
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            setHover(dot(at: g.location(in: self)))
        default:
            setHover(nil)
        }
    }

    // MARK: - Apple Pencil のダブルタップ

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        switch UIPencilInteraction.preferredTapAction {
        case .ignore:
            return
        case .showColorPalette:
            state.showColorsRequest += 1
        default:
            // 既定: ペンと消しゴムを切り替える（ほかのツールなら消しゴムへ）
            editor.tool = editor.tool == .eraser ? .pen : .eraser
            editor.stampActive = false
            state.eyedropperActive = false
        }
    }

    func cancelInteraction() {
        if case .stroke = interaction { editor.cancelEdit() }
        cancelPick()
        interaction = .none
        editor.stampActive = false
        setNeedsDisplay()
    }
}

struct MainCanvasRepresentable: UIViewRepresentable {
    let state: PadState

    func makeUIView(context: Context) -> MainPadView { MainPadView(state: state) }

    func updateUIView(_ v: MainPadView, context: Context) {
        // 表示に関わる状態を読んでおき、変わったら描き直させる
        let e = state.editor
        _ = (e.meta, e.tool, e.stampActive, e.color, e.shapeFilled, e.clipboard?.width, state.animPanelVisible, state.onionSkin, state.selectedAnimID,
             state.eyedropperActive)
        v.setNeedsDisplay()
    }
}
