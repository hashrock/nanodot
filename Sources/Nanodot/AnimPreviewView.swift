import AppKit
import NanodotCore
import SwiftUI

/// 選択中のアニメを常時再生する
final class AnimPreviewView: NSView {
    let state: AppState
    private var timer: Timer?
    private var frameIndex = 0
    private var nextFrameTime: CFTimeInterval = 0
    var playing = true {
        didSet { if playing && !oldValue { nextFrameTime = 0 } }
    }

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else {
            // ウィンドウを閉じたらストックのコマ枠も消す
            state.previewFrameRect = nil
            state.stockView?.needsDisplay = true
            return
        }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var anim: AnimDef? { state.editor.meta.anims.first { $0.id == state.selectedAnimID } }

    private func tick() {
        guard let anim else {
            setFrameRect(nil)
            return
        }
        let frames = anim.resolvedFrames
        guard !frames.isEmpty else {
            setFrameRect(nil)
            return
        }
        if frameIndex >= frames.count { frameIndex = 0 }
        let now = CACurrentMediaTime()
        if playing {
            if nextFrameTime == 0 { nextFrameTime = now + Double(frames[frameIndex].duration) / 1000 }
            if now >= nextFrameTime {
                frameIndex = (frameIndex + 1) % frames.count
                nextFrameTime = now + Double(frames[frameIndex].duration) / 1000
                needsDisplay = true
            }
        }
        setFrameRect(anim.rect(of: frames[frameIndex]))
    }

    private func setFrameRect(_ r: IntRect?) {
        guard state.previewFrameRect != r else { return }
        state.previewFrameRect = r
        state.stockView?.needsDisplay = true
        needsDisplay = true
    }

    func step(_ d: Int) {
        guard let n = anim?.resolvedFrames.count, n > 0 else { return }
        frameIndex = ((frameIndex + d) % n + n) % n
        nextFrameTime = 0
        tick()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.underPageBackgroundColor.cgColor)
        ctx.fill(bounds)
        guard let r = state.previewFrameRect, r.width > 0, r.height > 0 else { return }
        let fz = min((bounds.width - 8) / CGFloat(r.width), (bounds.height - 8) / CGFloat(r.height))
        let z = fz >= 1 ? floor(fz) : fz
        let size = CGSize(width: CGFloat(r.width) * z, height: CGFloat(r.height) * z)
        let dest = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
        Draw.fillChecker(ctx, dest, origin: dest.origin, dot: z)
        // シート外にはみ出たコマは透明として扱う
        let img = state.editor.image
        let inside = r.intersection(img.bounds)
        if !inside.isEmpty, let cg = state.sheetImage, let part = Draw.crop(cg, inside) {
            let d = CGRect(x: dest.minX + CGFloat(inside.x - r.x) * z, y: dest.minY + CGFloat(inside.y - r.y) * z,
                           width: CGFloat(inside.width) * z, height: CGFloat(inside.height) * z)
            Draw.image(ctx, part, in: d)
        }
    }
}

struct AnimPreviewRepresentable: NSViewRepresentable {
    let state: AppState
    let playing: Bool

    func makeNSView(context: Context) -> AnimPreviewView {
        let v = AnimPreviewView(state: state)
        state.previewView = v
        return v
    }

    func updateNSView(_ nsView: AnimPreviewView, context: Context) {
        nsView.playing = playing
        _ = (state.editor.meta.anims, state.selectedAnimID)
        nsView.needsDisplay = true
    }
}
