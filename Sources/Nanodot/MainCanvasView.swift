import AppKit
import NanodotCore
import SwiftUI

/// メインウィンドウ: マーク範囲を拡大して描く
final class MainCanvasView: NSView {
    let state: AppState
    var editor: Editor { state.editor }

    private enum Interaction {
        case none
        case stroke(last: IntPoint, color: RGBA)
        case shape(start: IntPoint, current: IntPoint)
        /// 右ボタンを押した直後（離せばスポイト、動かせば範囲選択）
        case rightPending(start: IntPoint)
        case rightSelect(start: IntPoint, current: IntPoint)
        /// スペース + ドラッグでマーク位置を動かす
        case pan(start: CGPoint, startMark: IntPoint)
    }

    private var interaction = Interaction.none
    private var hoverDot: IntPoint?
    private var scrollAccum = CGPoint.zero
    private var spaceHeld = false
    private var trackingArea: NSTrackingArea?

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
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    private func updateCursor() {
        if case .pan = interaction {
            NSCursor.closedHand.set()
        } else if spaceHeld {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    func setSpaceHeld(_ held: Bool) {
        guard held != spaceHeld else { return }
        spaceHeld = held
        if window?.isKeyWindow == true, let w = window, bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) {
            updateCursor()
        }
    }

    /// パンの単位（セルの 1/8）
    private var panUnit: (x: Int, y: Int) {
        (max(1, editor.meta.cellWidth / 8), max(1, editor.meta.cellHeight / 8))
    }

    // MARK: - 座標

    private let padding: CGFloat = 24

    /// ルーペ範囲が収まる倍率（1 以上なら整数）
    var zoom: CGFloat {
        let m = editor.meta
        let z = min((bounds.width - padding * 2) / CGFloat(m.lupeWidth), (bounds.height - padding * 2) / CGFloat(m.lupeHeight))
        return z >= 1 ? floor(z) : max(z, 0.05)
    }

    /// マーク位置（左上）の画面座標
    private var markOrigin: CGPoint {
        let m = editor.meta, z = zoom
        return CGPoint(x: ((bounds.width - CGFloat(m.lupeWidth) * z) / 2).rounded(),
                       y: ((bounds.height - CGFloat(m.lupeHeight) * z) / 2).rounded())
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

    private func dot(_ e: NSEvent) -> IntPoint { dot(at: convert(e.locationInWindow, from: nil)) }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ctx.setFillColor(NSColor.underPageBackgroundColor.cgColor)
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
        if case .shape(let a, let b) = interaction {
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
        Draw.outline(ctx, mark.insetBy(dx: -1, dy: -1), color: NSColor.controlAccentColor.cgColor)

        // 右ドラッグの範囲
        if case .rightSelect(let a, let b) = interaction {
            Draw.outline(ctx, screenRect(IntRect(corner: a, b)))
        }

        // スタンプの影、またはカーソル位置のドット
        if let h = hoverDot {
            if editor.stampActive, let clip = editor.clipboard {
                let r = screenRect(IntRect(x: h.x, y: h.y, width: clip.width, height: clip.height))
                if let cg = SheetFile.cgImage(from: clip) { Draw.image(ctx, cg, in: r, alpha: 0.75) }
                Draw.outline(ctx, r)
            } else if editor.tool == .text, let (buf, img) = textPreview() {
                // テキストはカーソル位置を左上にして描いた結果を重ねる
                let r = screenRect(IntRect(x: h.x, y: h.y, width: buf.width, height: buf.height))
                Draw.image(ctx, img, in: r, alpha: 0.8)
                Draw.outline(ctx, r)
            } else if case .rightSelect = interaction {
            } else if z >= 4 {
                Draw.outline(ctx, screenRect(IntRect(x: h.x, y: h.y, width: 1, height: 1)))
            }
        }
    }

    private var textCache: (key: String, buf: PixelBuffer, img: CGImage)?

    /// テキストツールのプレビュー（設定と色が同じなら使い回す）
    private func textPreview() -> (PixelBuffer, CGImage)? {
        let s = editor.textSettings
        let key = "\(s.hashValue)-\(editor.color.hex)"
        if let c = textCache, c.key == key { return (c.buf, c.img) }
        guard let buf = TextRenderer.render(s.text, settings: s, color: editor.color), let img = SheetFile.cgImage(from: buf) else {
            textCache = nil
            return nil
        }
        textCache = (key, buf, img)
        return (buf, img)
    }

    /// アニメウィンドウを開いていて、マーク位置がアニメのコマと同じなら、前のコマを赤・次のコマを青で下に重ねる
    private func drawOnionSkin(_ ctx: CGContext) {
        guard state.animWindowVisible, state.onionSkin,
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

    // MARK: - マウス

    private func setHover(_ d: IntPoint?) {
        guard d != hoverDot else { return }
        hoverDot = d
        state.cursorDot = d.flatMap { editor.image.contains($0.x, $0.y) ? $0 : nil }
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) { setHover(dot(e)) }
    override func mouseExited(with e: NSEvent) { setHover(nil) }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        // フォーカスが外れている間にスペースを離した場合の取りこぼし対策
        if spaceHeld && !CGEventSource.keyState(.combinedSessionState, key: 49) { spaceHeld = false }
        if spaceHeld {
            interaction = .pan(start: convert(e.locationInWindow, from: nil), startMark: editor.meta.mark)
            updateCursor()
            return
        }
        let d = dot(e)
        setHover(d)
        if editor.stampActive {
            editor.stamp(at: d, overwrite: !e.modifierFlags.contains(.option), clipToWork: true)
            return
        }
        switch editor.tool {
        case .pen, .eraser:
            let c = editor.tool == .eraser ? RGBA.clear : editor.color
            editor.beginEdit()
            editor.plot([d], color: c)
            interaction = .stroke(last: d, color: c)
        case .fill:
            editor.floodFill(at: d, color: editor.color)
        case .line, .rect, .ellipse:
            interaction = .shape(start: d, current: d)
            needsDisplay = true
        case .text:
            editor.drawText(editor.textSettings.text, at: d, settings: editor.textSettings, color: editor.color)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        if case .pan(let start, let startMark) = interaction {
            let p = convert(e.locationInWindow, from: nil)
            let (ux, uy) = panUnit
            let z = zoom
            let dx = Int(((start.x - p.x) / z / CGFloat(ux)).rounded()) * ux
            let dy = Int(((start.y - p.y) / z / CGFloat(uy)).rounded()) * uy
            let m = IntPoint(startMark.x + dx, startMark.y + dy)
            if editor.clampedMark(m) != editor.meta.mark {
                editor.setMark(m)
                state.stockView?.scrollMarkToVisible()
                state.requestDisplay()
            }
            return
        }
        let d = dot(e)
        setHover(d)
        switch interaction {
        case .stroke(let last, let c):
            guard d != last else { return }
            editor.plot(Raster.line(last, d), color: c)
            interaction = .stroke(last: d, color: c)
        case .shape(let a, _):
            let b = e.modifierFlags.contains(.shift) ? Raster.constrain(a, d, diagonalSnap: editor.tool == .line) : d
            interaction = .shape(start: a, current: b)
            needsDisplay = true
        default:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        switch interaction {
        case .stroke:
            editor.endEdit(editor.tool == .eraser ? "消しゴム" : "ペン")
        case .shape(let a, let b):
            editor.drawShape(editor.tool, from: a, to: b, filled: editor.shapeFilled, color: editor.color)
        default:
            break
        }
        interaction = .none
        updateCursor()
        needsDisplay = true
    }

    override func rightMouseDown(with e: NSEvent) {
        if editor.stampActive {
            editor.stampActive = false
            interaction = .none
            needsDisplay = true
            return
        }
        if case .none = interaction { interaction = .rightPending(start: dot(e)) }
    }

    override func rightMouseDragged(with e: NSEvent) {
        let d = dot(e)
        setHover(d)
        switch interaction {
        case .rightPending(let s):
            if max(abs(d.x - s.x), abs(d.y - s.y)) >= max(1, state.dragThreshold) {
                interaction = .rightSelect(start: s, current: d)
                needsDisplay = true
            }
        case .rightSelect(let s, _):
            interaction = .rightSelect(start: s, current: d)
            needsDisplay = true
        default:
            break
        }
    }

    override func rightMouseUp(with e: NSEvent) {
        switch interaction {
        case .rightPending(let s):
            editor.pick(at: s)
        case .rightSelect(let a, let b):
            if let buf = editor.copy(IntRect(corner: a, b)) {
                state.setClipboard(buf)
                editor.stampActive = true
            }
        default:
            break
        }
        interaction = .none
        needsDisplay = true
    }

    /// ホイールで拡大縮小（ルーペサイズを 1/2・2 倍に。カーソル下のドットを中心に）
    override func scrollWheel(with e: NSEvent) {
        var steps = 0
        if e.hasPreciseScrollingDeltas {
            scrollAccum.y += e.scrollingDeltaY
            let step: CGFloat = 40
            steps = Int(scrollAccum.y / step)
            guard steps != 0 else { return }
            scrollAccum.y -= CGFloat(steps) * step
        } else {
            let dy = e.scrollingDeltaY
            steps = dy > 0 ? 1 : dy < 0 ? -1 : 0
        }
        guard steps != 0, !editor.isEditing else { return }
        let anchor = dot(e)
        for _ in 0..<abs(steps) { editor.zoomLupe(zoomIn: steps > 0, anchor: anchor) }
        state.stockView?.scrollMarkToVisible()
        state.requestDisplay()
        setHover(dot(e))
    }

    func cancelInteraction() {
        if case .stroke = interaction { editor.cancelEdit() }
        interaction = .none
        editor.stampActive = false
        needsDisplay = true
    }
}

struct MainCanvasRepresentable: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> MainCanvasView {
        let v = MainCanvasView(state: state)
        state.mainView = v
        return v
    }

    func updateNSView(_ nsView: MainCanvasView, context: Context) {
        // 表示に関わる状態を読んでおき、変わったら再描画させる
        let e = state.editor
        _ = (e.meta, e.tool, e.stampActive, e.color, e.shapeFilled, e.highlight, e.textSettings, state.animWindowVisible, state.onionSkin, state.selectedAnimID)
        nsView.needsDisplay = true
    }
}
