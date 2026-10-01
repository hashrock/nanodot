import AppKit
import NanodotCore
import SwiftUI

/// ストックウィンドウ: シート全体を表示し、マーク位置の指定・コピー・貼り付け・入れ替えを行う
final class StockView: NSView {
    let state: AppState
    var editor: Editor { state.editor }

    private enum Interaction {
        case none
        /// マーク位置を追従させる
        case moveMark
        /// マーク範囲を掴んで移動先と入れ替える
        case swap(start: IntPoint, target: IntPoint?)
        /// マーク範囲の右下を掴んでルーペサイズを変える
        case resize
        /// スペース + ドラッグで表示を動かす
        case pan(start: CGPoint, startOrigin: CGPoint)
        /// 右ボタンで範囲コピー（マークの大きさ単位で広がる）
        case copy(start: IntPoint, current: IntPoint)
    }

    private var interaction = Interaction.none
    private(set) var zoom: CGFloat = 2 {
        didSet { if state.stockZoom != zoom { state.stockZoom = zoom } }
    }
    /// シート左上の画面座標
    private var imageOrigin = CGPoint(x: 8, y: 8)
    private var hoverDot: IntPoint?
    private var magnifyAccum: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var didFit = false
    private var spaceHeld = false
    private let vScroller = NSScroller()
    private let hScroller = NSScroller()
    private let margin: CGFloat = 8

    /// 倍率の段階（縦長のシートも全体を見渡せるよう 1 未満もある）
    private static let zoomLevels: [CGFloat] = [0.125, 0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16]

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        clipsToBounds = true
        for (sc, action) in [(vScroller, #selector(vScrolled)), (hScroller, #selector(hScrolled))] {
            sc.scrollerStyle = .legacy
            sc.controlSize = .small
            sc.isEnabled = true
            sc.target = self
            sc.action = action
            sc.isHidden = true
            addSubview(sc)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
        super.updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        if !didFit && bounds.width > 0 {
            didFit = true
            fitToView()
        } else {
            clampOrigin()
        }
    }

    // MARK: - 表示範囲

    private var scrollerWidth: CGFloat { NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy) }
    private var contentSize: CGSize {
        CGSize(width: CGFloat(editor.image.width) * zoom + margin * 2, height: CGFloat(editor.image.height) * zoom + margin * 2)
    }

    /// スクロールバーを除いた表示領域
    private var viewport: CGRect {
        let c = contentSize, sw = scrollerWidth
        var needV = c.height > bounds.height, needH = c.width > bounds.width
        if needV && !needH { needH = c.width > bounds.width - sw }
        if needH && !needV { needV = c.height > bounds.height - sw }
        return CGRect(x: 0, y: 0, width: bounds.width - (needV ? sw : 0), height: bounds.height - (needH ? sw : 0))
    }

    /// シートの幅が収まる倍率で表示（縦長なら縦はスクロール）
    func fitToView() {
        let img = editor.image
        guard bounds.width > 0, img.width > 0 else { return }
        let avail = bounds.width - margin * 2 - scrollerWidth
        let z = avail / CGFloat(img.width)
        zoom = Self.zoomLevels.last { $0 <= min(z, 8) } ?? Self.zoomLevels[0]
        imageOrigin = CGPoint(x: margin, y: margin)
        clampOrigin()
        scrollMarkToVisible()
        needsDisplay = true
    }

    /// 表示領域の中央を中心に拡大縮小
    func stepZoom(_ d: Int) {
        let vp = viewport
        stepZoom(d, around: CGPoint(x: vp.midX, y: vp.midY))
    }

    private func stepZoom(_ d: Int, around p: CGPoint) {
        let i = Self.zoomLevels.firstIndex { $0 >= zoom } ?? Self.zoomLevels.count - 1
        let nz = Self.zoomLevels[min(max(0, i + d), Self.zoomLevels.count - 1)]
        guard nz != zoom else { return }
        let ix = (p.x - imageOrigin.x) / zoom, iy = (p.y - imageOrigin.y) / zoom
        zoom = nz
        imageOrigin = CGPoint(x: p.x - ix * nz, y: p.y - iy * nz)
        clampOrigin()
        needsDisplay = true
    }

    /// シートが見えなくならないように制限（収まるなら左上に寄せる）し、スクロールバーを合わせる
    private func clampOrigin() {
        let c = contentSize, vp = viewport
        func clamp(_ v: CGFloat, content: CGFloat, view: CGFloat) -> CGFloat {
            if content <= view { return margin }
            return min(margin, max(view - content + margin, v))
        }
        imageOrigin = CGPoint(x: clamp(imageOrigin.x, content: c.width, view: vp.width).rounded(),
                              y: clamp(imageOrigin.y, content: c.height, view: vp.height).rounded())
        updateScrollers()
    }

    private func updateScrollers() {
        let c = contentSize, vp = viewport, sw = scrollerWidth
        vScroller.isHidden = vp.height >= c.height
        hScroller.isHidden = vp.width >= c.width
        vScroller.frame = CGRect(x: bounds.width - sw, y: 0, width: sw, height: vp.height)
        hScroller.frame = CGRect(x: 0, y: bounds.height - sw, width: vp.width, height: sw)
        if !vScroller.isHidden {
            vScroller.knobProportion = vp.height / c.height
            vScroller.doubleValue = Double((margin - imageOrigin.y) / (c.height - vp.height))
        }
        if !hScroller.isHidden {
            hScroller.knobProportion = vp.width / c.width
            hScroller.doubleValue = Double((margin - imageOrigin.x) / (c.width - vp.width))
        }
    }

    @objc private func vScrolled(_ sender: NSScroller) {
        let c = contentSize, vp = viewport
        scrollerMoved(sender, page: vp.height) { imageOrigin.y = margin - CGFloat($0) * (c.height - vp.height) } offset: { imageOrigin.y += $0 }
    }

    @objc private func hScrolled(_ sender: NSScroller) {
        let c = contentSize, vp = viewport
        scrollerMoved(sender, page: vp.width) { imageOrigin.x = margin - CGFloat($0) * (c.width - vp.width) } offset: { imageOrigin.x += $0 }
    }

    private func scrollerMoved(_ sender: NSScroller, page: CGFloat, set: (Double) -> Void, offset: (CGFloat) -> Void) {
        switch sender.hitPart {
        case .knob, .knobSlot: set(sender.doubleValue)
        case .decrementPage: offset(page * 0.9)
        case .incrementPage: offset(-page * 0.9)
        default: break
        }
        clampOrigin()
        needsDisplay = true
    }

    func scrollMarkToVisible() {
        let r = screenRect(editor.markRect), vp = viewport
        var dx: CGFloat = 0, dy: CGFloat = 0
        if r.minX < 0 { dx = -r.minX + margin } else if r.maxX > vp.width { dx = vp.width - r.maxX - margin }
        if r.minY < 0 { dy = -r.minY + margin } else if r.maxY > vp.height { dy = vp.height - r.maxY - margin }
        guard dx != 0 || dy != 0 else { return }
        imageOrigin.x += dx
        imageOrigin.y += dy
        clampOrigin()
        needsDisplay = true
    }

    private func screenRect(_ r: IntRect) -> CGRect {
        CGRect(x: imageOrigin.x + CGFloat(r.x) * zoom, y: imageOrigin.y + CGFloat(r.y) * zoom,
               width: CGFloat(r.width) * zoom, height: CGFloat(r.height) * zoom)
    }

    /// ルーペサイズ変更のつまみ（マーク範囲の右下）
    private var resizeHandleRect: CGRect {
        let r = screenRect(editor.markRect)
        return CGRect(x: r.maxX - 5, y: r.maxY - 5, width: 10, height: 10)
    }

    private func isOnResizeHandle(_ e: NSEvent) -> Bool {
        resizeHandleRect.insetBy(dx: -2, dy: -2).contains(convert(e.locationInWindow, from: nil))
    }

    private func dot(_ e: NSEvent) -> IntPoint {
        let p = convert(e.locationInWindow, from: nil)
        return IntPoint(Int(floor((p.x - imageOrigin.x) / zoom)), Int(floor((p.y - imageOrigin.y) / zoom)))
    }

    private var markSize: (w: Int, h: Int) { (editor.meta.lupeWidth, editor.meta.lupeHeight) }

    /// 右ドラッグのコピー範囲: 起点と現在位置それぞれのマーク大の矩形を合わせたもの
    private func copyRect(_ a: IntPoint, _ b: IntPoint) -> IntRect {
        let (w, h) = markSize
        return IntRect(x: a.x, y: a.y, width: w, height: h).union(IntRect(x: b.x, y: b.y, width: w, height: h))
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ctx.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        ctx.fill(bounds)
        let img = editor.image
        let sheet = screenRect(img.bounds)
        Draw.fillChecker(ctx, sheet, origin: sheet.origin, dot: zoom)
        if let cg = state.sheetImage { Draw.image(ctx, cg, in: sheet) }

        if let h = editor.highlight, state.blinkOn {
            let lo = IntPoint(Int(floor(-imageOrigin.x / zoom)), Int(floor(-imageOrigin.y / zoom)))
            let area = IntRect(x: lo.x, y: lo.y, width: Int(bounds.width / zoom) + 2, height: Int(bounds.height / zoom) + 2)
            Draw.highlight(ctx, image: img, color: h, area: area) { x, y in self.screenRect(IntRect(x: x, y: y, width: 1, height: 1)) }
        }

        let m = editor.meta
        if m.showCellGrid {
            Draw.grid(ctx, area: sheet.intersection(bounds), origin: sheet.origin, stepX: CGFloat(m.cellWidth) * zoom,
                      stepY: CGFloat(m.cellHeight) * zoom, color: CGColor(srgbRed: 0.2, green: 0.55, blue: 1, alpha: 0.35))
        }

        if state.showAnnotations { drawAnnotations(ctx) }

        if let f = state.previewFrameRect {
            Draw.outline(ctx, screenRect(f), color: CGColor(srgbRed: 0.1, green: 0.8, blue: 0.4, alpha: 0.9), dashed: true)
        }

        // マーク位置
        let mark = screenRect(editor.markRect)
        ctx.saveGState()
        ctx.setLineWidth(2)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.15, blue: 0.2, alpha: 1))
        ctx.stroke(mark.insetBy(dx: -1, dy: -1))
        let handle = resizeHandleRect
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.15, blue: 0.2, alpha: 1))
        ctx.fill(handle)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1)
        ctx.stroke(handle.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()

        switch interaction {
        case .swap(_, let t?):
            let r = screenRect(IntRect(x: t.x, y: t.y, width: m.lupeWidth, height: m.lupeHeight))
            if let cg = state.sheetImage, let part = Draw.crop(cg, editor.markRect.intersection(img.bounds)) {
                Draw.image(ctx, part, in: CGRect(origin: r.origin, size: CGSize(width: CGFloat(part.width) * zoom, height: CGFloat(part.height) * zoom)), alpha: 0.8)
            }
            Draw.outline(ctx, r)
        case .copy(let a, let b):
            Draw.outline(ctx, screenRect(copyRect(a, b)))
        default:
            // 貼り付け位置の目安
            if let h = hoverDot, let clip = editor.clipboard {
                let p = m.snapped(h)
                Draw.outline(ctx, screenRect(IntRect(x: p.x, y: p.y, width: clip.width, height: clip.height)),
                             color: CGColor(gray: 1, alpha: 0.5), dashed: true)
            }
        }
    }

    /// 注釈のあるセルに、通行不可は ×、重なり順は ★数字、名前を重ねる
    private func drawAnnotations(_ ctx: CGContext) {
        let m = editor.meta
        guard !m.annotations.isEmpty else { return }
        let cw = m.cellWidth, ch = m.cellHeight
        let small = CGFloat(min(cw, ch)) * zoom < 28
        for a in m.annotations {
            let r = screenRect(IntRect(x: a.col * cw, y: a.row * ch, width: cw, height: ch))
            guard r.intersects(bounds) else { continue }
            if !a.passable {
                ctx.saveGState()
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.25, alpha: 0.18))
                ctx.fill(r)
                let x = r.insetBy(dx: r.width * 0.3, dy: r.height * 0.3)
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.25, alpha: 0.9))
                ctx.setLineWidth(2)
                ctx.move(to: CGPoint(x: x.minX, y: x.minY)); ctx.addLine(to: CGPoint(x: x.maxX, y: x.maxY))
                ctx.move(to: CGPoint(x: x.maxX, y: x.minY)); ctx.addLine(to: CGPoint(x: x.minX, y: x.maxY))
                ctx.strokePath()
                ctx.restoreGState()
            }
            guard !small else { continue }
            var labels: [String] = []
            if a.z != 0 { labels.append("★\(a.z)") }
            if !a.name.isEmpty { labels.append(a.name) }
            guard !labels.isEmpty else { continue }
            let text = NSAttributedString(string: labels.joined(separator: " "), attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            let size = text.size()
            let bg = CGRect(x: r.minX + 1, y: r.minY + 1, width: min(size.width + 4, r.width - 2), height: size.height)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
            ctx.fill(bg)
            text.draw(with: bg.insetBy(dx: 2, dy: 0), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    // MARK: - マウス

    private func setHover(_ d: IntPoint?) {
        guard d != hoverDot else { return }
        hoverDot = d
        state.cursorDot = d.flatMap { editor.image.contains($0.x, $0.y) ? $0 : nil }
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) {
        setHover(dot(e))
        updateCursor(e)
    }

    func setSpaceHeld(_ held: Bool) {
        guard held != spaceHeld else { return }
        spaceHeld = held
        if let w = window, w.isKeyWindow, bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) {
            if held { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        }
    }

    private func updateCursor(_ e: NSEvent) {
        if case .resize = interaction { return }
        if case .pan = interaction {
            NSCursor.closedHand.set()
        } else if spaceHeld {
            NSCursor.openHand.set()
        } else if isOnResizeHandle(e) {
            if #available(macOS 15.0, *) {
                NSCursor.frameResize(position: .bottomRight, directions: .all).set()
            } else {
                NSCursor.crosshair.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }
    override func mouseExited(with e: NSEvent) { setHover(nil) }

    override func mouseDown(with e: NSEvent) {
        if spaceHeld && !CGEventSource.keyState(.combinedSessionState, key: 49) { spaceHeld = false }
        if spaceHeld {
            interaction = .pan(start: convert(e.locationInWindow, from: nil), startOrigin: imageOrigin)
            updateCursor(e)
            return
        }
        let d = dot(e)
        if e.clickCount == 2 {
            interaction = .none
            guard editor.clipboard != nil else { return }
            editor.stamp(at: editor.meta.snapped(d), overwrite: !e.modifierFlags.contains(.option), clipToWork: false)
            return
        }
        if isOnResizeHandle(e) {
            interaction = .resize
        } else if editor.markRect.contains(d) {
            interaction = .swap(start: d, target: nil)
        } else {
            editor.setMark(editor.meta.snapped(d))
            interaction = .moveMark
        }
        state.requestDisplay()
    }

    override func mouseDragged(with e: NSEvent) {
        if case .pan(let start, let o) = interaction {
            let p = convert(e.locationInWindow, from: nil)
            imageOrigin = CGPoint(x: o.x + p.x - start.x, y: o.y + p.y - start.y)
            clampOrigin()
            needsDisplay = true
            return
        }
        let d = dot(e)
        setHover(d)
        switch interaction {
        case .moveMark:
            editor.setMark(editor.meta.snapped(d))
            state.requestDisplay()
        case .resize:
            // スナップ単位で大きさを変える（最小 1 単位）
            let m = editor.meta
            func size(_ v: Int, _ u: Int) -> Int { max(u, Int((Double(v) / Double(u)).rounded()) * u) }
            editor.setLupe(width: size(d.x - m.mark.x + 1, m.snapX), height: size(d.y - m.mark.y + 1, m.snapY))
            state.requestDisplay()
        case .swap(let s, _):
            let delta = editor.meta.snappedDelta(d - s)
            let t = editor.clampedMark(editor.meta.mark + delta)
            interaction = .swap(start: s, target: t == editor.meta.mark ? nil : t)
            needsDisplay = true
        default:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        switch interaction {
        case .swap(_, let t?):
            editor.swapMarkRegion(to: t)
        case .swap(let s, nil):
            // 掴んだだけで動かさなければ、普通のクリックとしてマーク位置を指定
            let d = dot(e)
            if d == s || editor.meta.snappedDelta(d - s) == .zero { editor.setMark(editor.meta.snapped(d)) }
        default:
            break
        }
        interaction = .none
        updateCursor(e)
        state.requestDisplay()
    }

    override func rightMouseDown(with e: NSEvent) {
        let p = editor.meta.snapped(dot(e))
        interaction = .copy(start: p, current: p)
        needsDisplay = true
    }

    override func rightMouseDragged(with e: NSEvent) {
        let d = dot(e)
        setHover(d)
        guard case .copy(let a, _) = interaction else { return }
        interaction = .copy(start: a, current: editor.meta.snapped(d))
        needsDisplay = true
    }

    override func rightMouseUp(with e: NSEvent) {
        if case .copy(let a, let b) = interaction, let buf = editor.copy(copyRect(a, b)) {
            state.setClipboard(buf)
        }
        interaction = .none
        state.requestDisplay()
    }

    /// マウスホイールで拡大縮小（カーソル位置を中心に）、⌥ で縦・Shift で横に移動。トラックパッドは 2 本指で移動、ピンチか ⌘ スクロールで拡大縮小
    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if !e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.shift) && !e.modifierFlags.contains(.option) {
            let dy = e.scrollingDeltaY
            if dy != 0 { stepZoom(dy > 0 ? 1 : -1, around: p) }
            setHover(dot(e))
            return
        }
        if e.modifierFlags.contains(.command) {
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 40 : e.scrollingDeltaY
            magnifyAccum += dy
            if abs(magnifyAccum) >= 1 {
                stepZoom(magnifyAccum > 0 ? 1 : -1, around: p)
                magnifyAccum = 0
            }
            return
        }
        var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas {
            // ⌥ + ホイールで縦移動、Shift + ホイールで横移動
            dx *= 16; dy *= 16
            if e.modifierFlags.contains(.shift) && dx == 0 { swap(&dx, &dy) }
        }
        imageOrigin.x += dx
        imageOrigin.y += dy
        clampOrigin()
        setHover(dot(e))
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

struct StockRepresentable: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> StockView {
        let v = StockView(state: state)
        state.stockView = v
        return v
    }

    func updateNSView(_ nsView: StockView, context: Context) {
        let e = state.editor
        _ = (e.meta, e.highlight, e.clipboard?.width, state.showAnnotations)
        nsView.needsDisplay = true
    }
}
