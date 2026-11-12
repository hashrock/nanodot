import NanodotCore
import SwiftUI
import UIKit

/// 選択中のアニメを常時再生する
final class AnimPreviewPadView: UIView {
    let state: PadState
    private var link: CADisplayLink?
    private var frameIndex = 0
    private var nextFrameTime: CFTimeInterval = 0
    var playing = true {
        didSet { if playing && !oldValue { nextFrameTime = 0 } }
    }

    init(state: PadState) {
        self.state = state
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        clipsToBounds = true
        state.previewView = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else {
            // パネルを閉じたらストックのコマ枠も消す
            state.previewFrameRect = nil
            state.stockView?.setNeedsDisplay()
            return
        }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private var anim: AnimDef? { state.editor.meta.anims.first { $0.id == state.selectedAnimID } }

    @objc private func tick() {
        guard let anim else { return setFrameRect(nil) }
        let frames = anim.resolvedFrames
        guard !frames.isEmpty else { return setFrameRect(nil) }
        if frameIndex >= frames.count { frameIndex = 0 }
        let now = CACurrentMediaTime()
        if playing {
            if nextFrameTime == 0 { nextFrameTime = now + Double(frames[frameIndex].duration) / 1000 }
            if now >= nextFrameTime {
                frameIndex = (frameIndex + 1) % frames.count
                nextFrameTime = now + Double(frames[frameIndex].duration) / 1000
                setNeedsDisplay()
            }
        }
        setFrameRect(anim.rect(of: frames[frameIndex]))
    }

    private func setFrameRect(_ r: IntRect?) {
        guard state.previewFrameRect != r else { return }
        state.previewFrameRect = r
        state.stockView?.setNeedsDisplay()
        setNeedsDisplay()
    }

    func step(_ d: Int) {
        guard let n = anim?.resolvedFrames.count, n > 0 else { return }
        frameIndex = ((frameIndex + d) % n + n) % n
        nextFrameTime = 0
        tick()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.secondarySystemBackground.cgColor)
        ctx.fill(bounds)
        guard let r = state.previewFrameRect, r.width > 0, r.height > 0 else { return }
        let fz = min((bounds.width - 8) / CGFloat(r.width), (bounds.height - 8) / CGFloat(r.height))
        let z = fz >= 1 ? floor(fz) : fz
        let size = CGSize(width: CGFloat(r.width) * z, height: CGFloat(r.height) * z)
        let dest = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
        Draw.fillChecker(ctx, dest, origin: dest.origin, dot: z)
        // シート外にはみ出たコマは透明として扱う
        let inside = r.intersection(state.editor.image.bounds)
        if !inside.isEmpty, let cg = state.sheetImage, let part = Draw.crop(cg, inside) {
            let d = CGRect(x: dest.minX + CGFloat(inside.x - r.x) * z, y: dest.minY + CGFloat(inside.y - r.y) * z,
                           width: CGFloat(inside.width) * z, height: CGFloat(inside.height) * z)
            Draw.image(ctx, part, in: d)
        }
    }
}

struct AnimPreviewRepresentable: UIViewRepresentable {
    let state: PadState
    let playing: Bool

    func makeUIView(context: Context) -> AnimPreviewPadView { AnimPreviewPadView(state: state) }

    func updateUIView(_ v: AnimPreviewPadView, context: Context) {
        v.playing = playing
        _ = (state.editor.meta.anims, state.selectedAnimID)
        v.setNeedsDisplay()
    }
}

/// アニメのパネル（Mac 版のアニメウィンドウにあたる）
struct AnimPanel: View {
    let state: PadState
    @Bindable var editor: Editor
    @State private var playing = true
    @State private var newFrameDuration = 150
    @State private var shareURL: URL?

    private var index: Int? { editor.meta.anims.firstIndex { $0.id == state.selectedAnimID } }

    var body: some View {
        if state.isOutsideDocument {
            OutsideNotice(state: state, feature: L("アニメ"))
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("アニメ", selection: Binding(get: { state.selectedAnimID }, set: { state.selectedAnimID = $0 })) {
                    if editor.meta.anims.isEmpty { Text("なし").tag(UUID?.none) }
                    ForEach(editor.meta.anims) { a in Text(a.name.isEmpty ? L("（無題）") : a.name).tag(UUID?.some(a.id)) }
                }
                .labelsHidden()
                Spacer()
                Button { addAnim() } label: { Image(systemName: "plus").frame(width: 32, height: 32) }
                    .accessibilityLabel("アニメを追加")
                Button(role: .destructive) {
                    if let i = index {
                        editor.meta.anims.remove(at: i)
                        state.selectedAnimID = editor.meta.anims.first?.id
                    }
                } label: { Image(systemName: "trash").frame(width: 32, height: 32) }
                    .disabled(index == nil)
                    .accessibilityLabel("アニメを削除")
            }

            if let i = index {
                editorFor($editor.meta.anims[i])
            } else {
                Text("＋ で、マーク位置からセルの大きさのアニメを作ります")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $shareURL) { url in ActivityView(items: [url]) }
    }

    private func addAnim() {
        let m = editor.meta
        var a = AnimDef(name: L("アニメ \(m.anims.count + 1)"), frameWidth: m.cellWidth, frameHeight: m.cellHeight)
        a.originX = m.mark.x
        a.originY = m.mark.y
        editor.meta.anims.append(a)
        state.selectedAnimID = a.id
    }

    @ViewBuilder
    private func editorFor(_ a: Binding<AnimDef>) -> some View {
        AnimPreviewRepresentable(state: state, playing: playing)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        HStack(spacing: 14) {
            Button { state.previewView?.step(-1) } label: { Image(systemName: "backward.frame") }
                .accessibilityLabel("前のコマ")
            Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                .accessibilityLabel(playing ? L("一時停止") : L("再生"))
            Button { state.previewView?.step(1) } label: { Image(systemName: "forward.frame") }
                .accessibilityLabel("次のコマ")
            Toggle("オニオンスキン", isOn: Binding(get: { state.onionSkin }, set: { state.onionSkin = $0 }))
                .toggleStyle(.button)
                .font(.callout)
            Spacer(minLength: 0)
            Menu {
                ForEach(AnimExport.Format.allCases, id: \.self) { f in
                    Menu(f.label) {
                        ForEach([1, 2, 3, 4, 8], id: \.self) { s in
                            Button("\(s) 倍") { shareURL = state.exportAnimFile(f, scale: s) }
                        }
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("書き出し")
        }
        .font(.title3)

        VStack(spacing: 8) {
            row("名前") { TextField("名前", text: a.name).textFieldStyle(.roundedBorder) }
            Picker("種類", selection: a.mode) {
                Text("簡易").tag(AnimDef.Mode.grid)
                Text("登録").tag(AnimDef.Mode.list)
            }
            .pickerStyle(.segmented)
            row("コマの大きさ") {
                HStack(spacing: 4) {
                    IntField(value: a.frameWidth, min: 1)
                    Text("×").fixedSize()
                    IntField(value: a.frameHeight, min: 1)
                    Menu {
                        Button("セルの大きさ") {
                            a.wrappedValue.frameWidth = editor.meta.cellWidth
                            a.wrappedValue.frameHeight = editor.meta.cellHeight
                        }
                        Button("ルーペの大きさ") {
                            a.wrappedValue.frameWidth = editor.meta.lupeWidth
                            a.wrappedValue.frameHeight = editor.meta.lupeHeight
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            switch a.wrappedValue.mode {
            case .grid:
                row("起点") {
                    HStack(spacing: 4) {
                        IntField(value: a.originX, min: 0)
                        Text(",").fixedSize()
                        IntField(value: a.originY, min: 0)
                        Button("マーク位置") {
                            a.wrappedValue.originX = editor.meta.mark.x
                            a.wrappedValue.originY = editor.meta.mark.y
                        }
                        .font(.callout)
                    }
                }
                row("列 × 行") {
                    HStack(spacing: 4) {
                        IntField(value: a.columns, min: 1)
                        Text("×").fixedSize()
                        IntField(value: a.rows, min: 1)
                    }
                }
                row("枚数") { IntField(value: a.count, min: 1) }
                row("間隔") {
                    HStack(spacing: 4) {
                        IntField(value: a.interval, min: 10, step: 10)
                        Text("ms")
                    }
                }
            case .list:
                row("追加") {
                    HStack(spacing: 4) {
                        IntField(value: $newFrameDuration, min: 10, step: 10)
                        Text("ms")
                        Button("マーク位置を追加") {
                            a.wrappedValue.frames.append(AnimFrame(x: editor.meta.mark.x, y: editor.meta.mark.y, duration: newFrameDuration))
                        }
                        .font(.callout)
                    }
                }
            }
        }

        if a.wrappedValue.mode == .list {
            FrameList(frames: a.frames) { f in
                editor.setMark(IntPoint(f.x, f.y))
                state.stockView?.scrollMarkToVisible()
                state.requestDisplay()
            }
        }
    }

    private func row<C: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content()
        }
    }
}

struct FrameList: View {
    @Binding var frames: [AnimFrame]
    let jump: (AnimFrame) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(frames.enumerated()), id: \.element.id) { i, f in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).frame(width: 22, alignment: .trailing)
                    Button("(\(f.x), \(f.y))") { jump(f) }
                        .font(.callout.monospacedDigit())
                        .accessibilityHint("マーク位置をこのコマへ")
                    Spacer()
                    IntField(value: $frames[i].duration, min: 10, step: 10)
                    Text("ms").font(.caption)
                    Menu {
                        Button { frames.swapAt(i, i - 1) } label: { Label("上へ", systemImage: "chevron.up") }
                            .disabled(i == 0)
                        Button { frames.swapAt(i, i + 1) } label: { Label("下へ", systemImage: "chevron.down") }
                            .disabled(i == frames.count - 1)
                        Button { frames.insert(AnimFrame(x: f.x, y: f.y, duration: f.duration), at: i + 1) } label: {
                            Label("複製", systemImage: "plus.square.on.square")
                        }
                        Button(role: .destructive) { frames.remove(at: i) } label: { Label("削除", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 30, height: 30)
                    }
                }
            }
            if frames.isEmpty {
                Text("マーク位置を動かしながら「マーク位置を追加」でコマを登録します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 整数の入力欄（範囲外は丸める）。両側の −／＋ で step ずつ変える（押し続けると繰り返す）
struct IntField: View {
    @Binding var value: Int
    var min: Int = 0
    var max: Int = 8192
    var step: Int = 1
    var width: CGFloat = 48

    private func set(_ v: Int) { value = Swift.min(Swift.max(v, min), max) }

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", L("減らす"), disabled: value <= min) {
                // step の倍数にそろえながら減らす（17 で −16 なら 16）
                set(value % step == 0 ? value - step : value - value % step)
            }
            TextField("", value: Binding(get: { value }, set: { set($0) }), format: .number.grouping(.never))
                .labelsHidden()
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .frame(width: width)
                .textFieldStyle(.roundedBorder)
            stepButton("plus", L("増やす"), disabled: value >= max) {
                set(value % step == 0 ? value + step : value - value % step + step)
            }
        }
    }

    private func stepButton(_ symbol: String, _ label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .frame(width: 28, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .buttonRepeatBehavior(.enabled)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

/// アプリのフォルダーの外の書類では使えない機能の代わりに出す案内
struct OutsideNotice: View {
    let state: PadState
    let feature: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(feature)は使えません", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.yellow)
            Text("この書類はアプリのフォルダーの外にあるので、設定（隣の「\(state.documentName).nanodot」）を読み書きしません。")
            Button {
                state.duplicateIntoAppFolder()
            } label: {
                Label("Nanodot のフォルダーに複製して開く", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 共有シート
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
