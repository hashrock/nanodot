import NanodotCore
import SwiftUI
import UIKit

/// ストック: シート全体を表示し、マーク位置の指定・入れ替え・ルーペサイズの変更・コピー・貼り付けを行う。
/// - 指 1 本か Apple Pencil:
///   - タップ／ドラッグ: マーク位置を指定（ドラッグで追従）
///   - マーク範囲の中からドラッグ: 移動先と入れ替え
///   - マーク範囲の右下のつまみをドラッグ: ルーペサイズを変える
///   - 長押し: マークと同じ大きさの範囲をコピー。そのままドラッグで広げる（Mac 版の右クリック・右ドラッグ）
///   - ダブルタップ: クリップボードを貼り付け（スナップした位置が左上）
/// - 指 2 本: ドラッグで表示を動かす、ピンチで拡大縮小
final class StockPadView: UIView, UIGestureRecognizerDelegate {
    let state: PadState
    var editor: Editor { state.editor }

    private enum Interaction {
        case none
        case moveMark
        case swap(start: IntPoint, target: IntPoint?)
        case resize
        case copy(start: IntPoint, current: IntPoint)
    }

    private var interaction = Interaction.none
    private(set) var zoom: CGFloat = 2 {
        didSet { if state.stockZoom != zoom { state.stockZoom = zoom } }
    }
    /// シート左上の画面座標
    private var imageOrigin = CGPoint(x: 8, y: 8)
    private var hoverDot: IntPoint?
    private var didFit = false
    private var scrollStart: CGPoint?
    private var pinchAccum: CGFloat = 0
    private let margin: CGFloat = 8

    private static let zoomLevels: [CGFloat] = [0.125, 0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16]

    private let drag = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let hold = UILongPressGestureRecognizer()
    private let scroll = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let hover = UIHoverGestureRecognizer()

    init(state: PadState) {
        self.state = state
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        clipsToBounds = true
        isMultipleTouchEnabled = true

        let any = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for g in [drag, tap, doubleTap, hold] as [UIGestureRecognizer] { g.allowedTouchTypes = any }
        for g in [scroll, pinch] as [UIGestureRecognizer] { g.allowedTouchTypes = direct }
        for g in [drag, tap, doubleTap, hold, scroll, pinch] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        drag.maximumNumberOfTouches = 1
        drag.addTarget(self, action: #selector(handleDrag(_:)))
        tap.addTarget(self, action: #selector(handleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        hold.minimumPressDuration = 0.4
        hold.addTarget(self, action: #selector(handleHold(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.addTarget(self, action: #selector(handleScroll(_:)))
        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        hover.addTarget(self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
        state.stockView = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !didFit && bounds.width > 0 {
            didFit = true
            fitToView()
        } else {
            clampOrigin()
            setNeedsDisplay()
        }
    }

    // MARK: - 表示範囲

    private var contentSize: CGSize {
        CGSize(width: CGFloat(editor.image.width) * zoom + margin * 2, height: CGFloat(editor.image.height) * zoom + margin * 2)
    }

    /// シートの幅が収まる倍率で表示（縦長なら縦はスクロール）
    func fitToView() {
        let img = editor.image
        guard bounds.width > 0, img.width > 0 else { return }
        let z = (bounds.width - margin * 2) / CGFloat(img.width)
        zoom = Self.zoomLevels.last { $0 <= min(z, 8) } ?? Self.zoomLevels[0]
        imageOrigin = CGPoint(x: margin, y: margin)
        clampOrigin()
        scrollMarkToVisible()
        setNeedsDisplay()
    }

    func stepZoom(_ d: Int) {
        stepZoom(d, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private func stepZoom(_ d: Int, around p: CGPoint) {
        let i = Self.zoomLevels.firstIndex { $0 >= zoom } ?? Self.zoomLevels.count - 1
        let nz = Self.zoomLevels[min(max(0, i + d), Self.zoomLevels.count - 1)]
        guard nz != zoom else { return }
        let ix = (p.x - imageOrigin.x) / zoom, iy = (p.y - imageOrigin.y) / zoom
        zoom = nz
        imageOrigin = CGPoint(x: p.x - ix * nz, y: p.y - iy * nz)
        clampOrigin()
        setNeedsDisplay()
    }

    /// シートが見えなくならないように制限する（収まるなら左上に寄せる）
    private func clampOrigin() {
        let c = contentSize
        func clamp(_ v: CGFloat, content: CGFloat, view: CGFloat) -> CGFloat {
            if content <= view { return margin }
            return min(margin, max(view - content + margin, v))
        }
        imageOrigin = CGPoint(x: clamp(imageOrigin.x, content: c.width, view: bounds.width).rounded(),
                              y: clamp(imageOrigin.y, content: c.height, view: bounds.height).rounded())
    }

    func scrollMarkToVisible() {
        let r = screenRect(editor.markRect)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if r.minX < 0 { dx = -r.minX + margin } else if r.maxX > bounds.width { dx = bounds.width - r.maxX - margin }
        if r.minY < 0 { dy = -r.minY + margin } else if r.maxY > bounds.height { dy = bounds.height - r.maxY - margin }
        guard dx != 0 || dy != 0 else { return }
        imageOrigin.x += dx
        imageOrigin.y += dy
        clampOrigin()
        setNeedsDisplay()
    }

    private func screenRect(_ r: IntRect) -> CGRect {
        CGRect(x: imageOrigin.x + CGFloat(r.x) * zoom, y: imageOrigin.y + CGFloat(r.y) * zoom,
               width: CGFloat(r.width) * zoom, height: CGFloat(r.height) * zoom)
    }

    /// ルーペサイズ変更のつまみ（マーク範囲の右下）。指で掴めるよう、当たり判定は見た目より広い
    private var resizeHandleRect: CGRect {
        let r = screenRect(editor.markRect)
        return CGRect(x: r.maxX - 7, y: r.maxY - 7, width: 14, height: 14)
    }

    private func isOnResizeHandle(_ p: CGPoint) -> Bool {
        resizeHandleRect.insetBy(dx: -12, dy: -12).contains(p)
    }

    private func dot(at p: CGPoint) -> IntPoint {
        IntPoint(Int(floor((p.x - imageOrigin.x) / zoom)), Int(floor((p.y - imageOrigin.y) / zoom)))
    }

    /// 長押しドラッグのコピー範囲: 起点と現在位置それぞれのマーク大の矩形を合わせたもの
    private func copyRect(_ a: IntPoint, _ b: IntPoint) -> IntRect {
        let w = editor.meta.lupeWidth, h = editor.meta.lupeHeight
        return IntRect(x: a.x, y: a.y, width: w, height: h).union(IntRect(x: b.x, y: b.y, width: w, height: h))
    }

    // MARK: - 描画

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.interpolationQuality = .none
        ctx.setFillColor(UIColor.secondarySystemBackground.cgColor)
        ctx.fill(bounds)
        let img = editor.image
        let sheet = screenRect(img.bounds)
        Draw.fillChecker(ctx, sheet.intersection(bounds), origin: sheet.origin, dot: zoom)
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

        if let f = state.previewFrameRect, state.animPanelVisible {
            Draw.outline(ctx, screenRect(f), color: CGColor(srgbRed: 0.1, green: 0.8, blue: 0.4, alpha: 0.9), dashed: true)
        }

        // マーク位置
        let mark = screenRect(editor.markRect)
        let red = CGColor(srgbRed: 1, green: 0.15, blue: 0.2, alpha: 1)
        ctx.saveGState()
        ctx.setLineWidth(2)
        ctx.setStrokeColor(red)
        ctx.stroke(mark.insetBy(dx: -1, dy: -1))
        let handle = resizeHandleRect
        ctx.setFillColor(red)
        ctx.fillEllipse(in: handle)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: handle.insetBy(dx: 0.75, dy: 0.75))
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
            // 貼り付け位置の目安（Apple Pencil を近づけたとき）
            if let h = hoverDot, let clip = editor.clipboard {
                let p = m.snapped(h)
                Draw.outline(ctx, screenRect(IntRect(x: p.x, y: p.y, width: clip.width, height: clip.height)),
                             color: CGColor(gray: 1, alpha: 0.5), dashed: true)
            }
        }
    }

    // MARK: - 操作

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === scroll && other === pinch) || (g === pinch && other === scroll)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        editor.setMark(editor.meta.snapped(dot(at: g.location(in: self))))
        state.requestDisplay()
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard editor.clipboard != nil else {
            state.show(L("貼り付ける画像がありません（長押しでコピーします）"))
            return
        }
        editor.stamp(at: editor.meta.snapped(dot(at: g.location(in: self))), overwrite: !state.stampSkipTransparent, clipToWork: false)
    }

    @objc private func handleDrag(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        let d = dot(at: p)
        switch g.state {
        case .began:
            // 認識までに少し動くので、押した位置から判断する
            let t = g.translation(in: self)
            let start = CGPoint(x: p.x - t.x, y: p.y - t.y)
            let s = dot(at: start)
            if isOnResizeHandle(start) {
                interaction = .resize
            } else if editor.markRect.contains(s) {
                interaction = .swap(start: s, target: nil)
            } else {
                interaction = .moveMark
            }
            handleDrag(g, changedTo: d)
        case .changed:
            handleDrag(g, changedTo: d)
        case .ended:
            if case .swap(_, let t?) = interaction { editor.swapMarkRegion(to: t) }
            interaction = .none
            state.requestDisplay()
        default:
            interaction = .none
            state.requestDisplay()
        }
    }

    private func handleDrag(_ g: UIPanGestureRecognizer, changedTo d: IntPoint) {
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
            setNeedsDisplay()
        default:
            break
        }
    }

    @objc private func handleHold(_ g: UILongPressGestureRecognizer) {
        let p = editor.meta.snapped(dot(at: g.location(in: self)))
        switch g.state {
        case .began:
            interaction = .copy(start: p, current: p)
            UISelectionFeedbackGenerator().selectionChanged()
            setNeedsDisplay()
        case .changed:
            guard case .copy(let a, _) = interaction else { return }
            interaction = .copy(start: a, current: p)
            setNeedsDisplay()
        case .ended:
            if case .copy(let a, let b) = interaction, let buf = editor.copy(copyRect(a, b)) {
                state.setClipboard(buf)
                state.show(L("\(buf.width)×\(buf.height) をコピーしました（ダブルタップで貼り付け）"))
            }
            interaction = .none
            state.requestDisplay()
        default:
            interaction = .none
            setNeedsDisplay()
        }
    }

    @objc private func handleScroll(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            scrollStart = imageOrigin
        case .changed:
            guard let o = scrollStart else { return }
            let t = g.translation(in: self)
            imageOrigin = CGPoint(x: o.x + t.x, y: o.y + t.y)
            clampOrigin()
            setNeedsDisplay()
        default:
            scrollStart = nil
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchAccum = 0
        case .changed:
            pinchAccum += log2(g.scale)
            g.scale = 1
            guard abs(pinchAccum) >= 0.5 else { return }
            let d = pinchAccum > 0 ? 1 : -1
            pinchAccum = 0
            stepZoom(d, around: g.location(in: self))
            scrollStart = imageOrigin
            scroll.setTranslation(.zero, in: self)
        default:
            pinchAccum = 0
        }
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        let d: IntPoint? = (g.state == .began || g.state == .changed) ? dot(at: g.location(in: self)) : nil
        guard d != hoverDot else { return }
        hoverDot = d
        setNeedsDisplay()
    }
}

struct StockRepresentable: UIViewRepresentable {
    let state: PadState

    func makeUIView(context: Context) -> StockPadView { StockPadView(state: state) }

    func updateUIView(_ v: StockPadView, context: Context) {
        let e = state.editor
        _ = (e.meta, e.clipboard?.width, state.animPanelVisible)
        v.setNeedsDisplay()
    }
}
