import AppKit
import NanodotCore
import SwiftUI

// MARK: - パレット

struct Swatch: View {
    let color: RGBA
    var count: Int?
    var selected = false
    var size: CGFloat = 18
    /// 枠線（隙間なく並べるときは消す）
    var border = true

    var body: some View {
        ZStack {
            if color.a < 255 { CheckerBackground(size: size / 4) }
            Rectangle().fill(color.swiftUIColor)
            if let count, count <= 99 {
                Text("\(count)")
                    .font(.system(size: 8, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 0, x: 1, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if selected {
                // どんな色の上でも見えるよう白黒の二重枠
                Rectangle().strokeBorder(Color.black, lineWidth: 3)
                Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
            } else if border {
                Rectangle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
            }
        }
    }
}

struct PalettePanel: View {
    let state: AppState
    @Bindable var editor: Editor
    @AppStorage("showColorCounts") private var showCounts = true

    /// どの色見本を押したか（同じ色が複数あっても、押したものだけを選択表示にする）
    private enum SwatchID: Hashable {
        case palette(Int)
        case slot(Int)
        /// カラーピッカーのプレビュー（描画色）
        case current
    }

    @State private var selected: SwatchID?
    /// Shift クリックで広げたスロットの範囲の端
    @State private var rangeEnd: Int?
    /// ドラッグ中の色見本と落とし先のスロット
    @State private var drag: (source: SwatchID, color: RGBA, target: Int?, location: CGPoint)?
    @State private var pressing = false
    /// Shift クリックの押下ではドラッグしない
    @State private var pressIsRange = false
    /// スロットの格子の位置（パネル内の座標。ドロップ先を求める）
    @State private var slotsFrame = CGRect.zero
    private static let cell: CGFloat = 22

    private var selectedRange: ClosedRange<Int>? {
        guard case .slot(let a) = selected, let e = rangeEnd, e != a else { return nil }
        return min(a, e)...max(a, e)
    }

    private func isSelected(_ id: SwatchID) -> Bool {
        if selected == id { return true }
        if case .slot(let i) = id, let r = selectedRange { return r.contains(i) }
        return false
    }

    private func slotIndex(at p: CGPoint) -> Int? {
        let f = slotsFrame
        guard f.contains(p) else { return nil }
        let cols = max(1, Int(f.width / Self.cell))
        let col = Int((p.x - f.minX) / Self.cell), row = Int((p.y - f.minY) / Self.cell)
        guard col < cols else { return nil }
        let i = row * cols + col
        return i < SheetMeta.slotCount ? i : nil
    }

    /// 押す: 描画色にして使用箇所を点滅（空きスロットなら描画色を登録）
    /// Shift + 押す: スロットの範囲選択
    /// ドラッグ: スロットへ移動（スロット同士は入れ替え、⌥ でコピー）
    private func swatchGesture(_ id: SwatchID, color: RGBA?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { g in
                if !pressing {
                    pressing = true
                    pressIsRange = false
                    if NSEvent.modifierFlags.contains(.shift), case .slot(let i) = id, case .slot = selected {
                        rangeEnd = i
                        pressIsRange = true
                        return
                    }
                    if id == .current {
                        // 描画色のプレビュー: 選択は変えず、使用箇所の点滅だけ
                        if let color { state.setHighlight(color) }
                        return
                    }
                    selected = id
                    rangeEnd = nil
                    if let color {
                        editor.color = color
                        state.setHighlight(color)
                    }
                    return
                }
                guard !pressIsRange, let color, hypot(g.translation.width, g.translation.height) > 4 else { return }
                if drag == nil { state.setHighlight(nil) }
                drag = (id, color, slotIndex(at: g.location), g.location)
            }
            .onEnded { _ in
                pressing = false
                state.setHighlight(nil)
                if let d = drag, let t = d.target {
                    switch d.source {
                    case .slot(let from):
                        editor.meta.slots = SlotOps.move(editor.meta.slots, from: from, to: t, copy: NSEvent.modifierFlags.contains(.option))
                    case .palette, .current:
                        editor.meta.slots[t] = d.color
                    }
                    selected = .slot(t)
                    rangeEnd = nil
                }
                drag = nil
            }
    }

    private static let space = "palettePanel"

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ColorEditor(editor: editor, previewGesture: AnyGesture(swatchGesture(.current, color: editor.color).map { _ in () }))
                .frame(width: 260)
            Divider()
            palettes
        }
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .topLeading) {
            // ドラッグ中の色のゴースト
            if let d = drag {
                Swatch(color: d.color, size: Self.cell)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                    .overlay(alignment: .bottomTrailing) {
                        if d.target != nil, NSEvent.modifierFlags.contains(.option), case .slot = d.source {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: 4, y: 4)
                        }
                    }
                    .scaleEffect(1.15)
                    .opacity(0.9)
                    .position(x: d.location.x + 6, y: d.location.y + 6)
                    .allowsHitTesting(false)
            }
        }
    }

    private var palettes: some View {
        VStack(alignment: .leading, spacing: 8) {
            let palette = SamplePalette.named(editor.meta.palette)
            let counts = Dictionary(uniqueKeysWithValues: editor.colorStats().map { ($0.color, $0.count) })
            HStack {
                Picker("", selection: $editor.meta.palette) {
                    ForEach(SamplePalette.all) { p in Text("\(p.name)（\(p.colors.count) 色）").tag(p.name) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Toggle("使用数", isOn: $showCounts).toggleStyle(.checkbox).font(.caption)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 22, maximum: 22), spacing: 0)], alignment: .leading, spacing: 0) {
                ForEach(Array(palette.colors.enumerated()), id: \.offset) { i, c in
                    let n = counts[c] ?? 0
                    Swatch(color: c, count: showCounts ? n : nil, selected: isSelected(.palette(i)), size: 22, border: false)
                        .gesture(swatchGesture(.palette(i), color: c))
                        .help("\(c.hex)  \(n) ドット")
                        .contextMenu { colorMenu(c) }
                }
            }

            Text("スロット").font(.caption.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell, maximum: Self.cell), spacing: 0)], alignment: .leading, spacing: 0) {
                ForEach(0..<SheetMeta.slotCount, id: \.self) { i in
                    slot(i)
                        .overlay {
                            if drag?.target == i {
                                Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                        }
                        .opacity(drag.map { $0.source == .slot(i) && $0.target != nil ? 0.4 : 1 } ?? 1)
                }
            }
            .background(GeometryReader { g in
                let f = g.frame(in: .named(Self.space))
                Color.clear
                    .onAppear { slotsFrame = f }
                    .onChange(of: f) { _, new in slotsFrame = new }
            })
            if selectedRange != nil {
                rangeBar
            } else {
                slotEditBar
            }
        }
    }

    /// 選択中のスロットが空きなら登録、色と描画色が違えば反映する操作を出す
    @ViewBuilder
    private var slotEditBar: some View {
        if case .slot(let i) = selected, editor.meta.slots[i] == nil {
            HStack(spacing: 6) {
                Swatch(color: editor.color, size: 16)
                Button("スロット \(i + 1) に登録") { editor.meta.slots[i] = editor.color }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("描画色をこのスロットに登録 (⌘↩)")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(6)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
        } else if case .slot(let i) = selected, let old = editor.meta.slots[i], old != editor.color {
            HStack(spacing: 6) {
                Swatch(color: old, size: 16)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Swatch(color: editor.color, size: 16)
                Button("スロットに反映") { editor.meta.slots[i] = editor.color }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("描画色でスロット \(i + 1) を上書き (⌘↩)")
                Button("戻す") { editor.color = old }
                    .help("描画色をスロットの色に戻す")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(6)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    /// 範囲選択中のスロットへの操作
    @ViewBuilder
    private var rangeBar: some View {
        if let r = selectedRange {
            HStack(spacing: 6) {
                Text("\(r.count) 個").font(.caption)
                rangeButtons(r)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(6)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    @ViewBuilder
    private func rangeButtons(_ r: ClosedRange<Int>) -> some View {
        let slots = editor.meta.slots
        let canGradient = r.count >= 3 && slots[r.lowerBound] != nil && slots[r.upperBound] != nil
        Menu("グラデーション") {
            Button("RGB で補間") { editor.meta.slots = SlotOps.gradient(slots, r.lowerBound, r.upperBound, hsl: false) }
            Button("HSL で補間（色相は近い方向に回る）") { editor.meta.slots = SlotOps.gradient(slots, r.lowerBound, r.upperBound, hsl: true) }
        }
        .fixedSize()
        .disabled(!canGradient)
        .help("両端の色の間を補間して埋める")
        Button("反転") { editor.meta.slots = SlotOps.reversed(slots, r.lowerBound, r.upperBound) }
        Button("消去") {
            for i in r { editor.meta.slots[i] = nil }
        }
    }

    @ViewBuilder
    private func replaceMenu(_ c: RGBA) -> some View {
        Button("この色を描画色に置換（シート全体）") { editor.replaceColor(c, with: editor.color, inMarkOnly: false) }
            .disabled(c == editor.color)
        Button("この色を描画色に置換（マーク範囲）") { editor.replaceColor(c, with: editor.color, inMarkOnly: true) }
            .disabled(c == editor.color)
    }

    /// スロット全体に対する操作
    @ViewBuilder
    private var slotsMenu: some View {
        Button("パレットの色をスロットに追加") {
            var slots = editor.meta.slots
            for c in SamplePalette.named(editor.meta.palette).colors where !slots.contains(c) {
                guard let i = slots.firstIndex(where: { $0 == nil }) else { break }
                slots[i] = c
            }
            editor.meta.slots = slots
        }
        Button("すべてのスロットを消去") {
            editor.meta.slots = Array(repeating: nil, count: SheetMeta.slotCount)
        }
        .disabled(editor.meta.slots.allSatisfy { $0 == nil })
    }

    @ViewBuilder
    private func colorMenu(_ c: RGBA) -> some View {
        replaceMenu(c)
        Divider()
        Button("スロットに登録") {
            if let i = editor.meta.slots.firstIndex(where: { $0 == nil }) { editor.meta.slots[i] = c }
        }
    }

    @ViewBuilder
    private func slot(_ i: Int) -> some View {
        if let c = editor.meta.slots[i] {
            Swatch(color: c, selected: isSelected(.slot(i)), size: Self.cell, border: false)
                .gesture(swatchGesture(.slot(i), color: c))
                .help(c.hex)
                .contextMenu {
                    if let r = selectedRange, r.contains(i) {
                        rangeButtons(r)
                        Divider()
                    }
                    Button("描画色で上書き") { editor.meta.slots[i] = editor.color }
                    Button("消去") { editor.meta.slots[i] = nil }
                    Divider()
                    replaceMenu(c)
                    Divider()
                    slotsMenu
                }
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(isSelected(.slot(i)) ? 0.3 : 0.1))
                .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5))
                .frame(width: Self.cell, height: Self.cell)
                .contentShape(Rectangle())
                .gesture(swatchGesture(.slot(i), color: nil))
                .contextMenu {
                    if let r = selectedRange, r.contains(i) {
                        rangeButtons(r)
                        Divider()
                    }
                    Button("描画色を登録") { editor.meta.slots[i] = editor.color }
                    Divider()
                    slotsMenu
                }
        }
    }
}

// MARK: - アニメ

struct AnimPanel: View {
    let state: AppState
    @Bindable var editor: Editor
    @State private var playing = true
    @State private var newFrameDuration = 150

    private var index: Int? { editor.meta.anims.firstIndex { $0.id == state.selectedAnimID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("アニメ").font(.caption.bold())
                Picker("", selection: Binding(get: { state.selectedAnimID }, set: { state.selectedAnimID = $0 })) {
                    if editor.meta.anims.isEmpty { Text("なし").tag(UUID?.none) }
                    ForEach(editor.meta.anims) { a in Text(a.name.isEmpty ? "（無題）" : a.name).tag(UUID?.some(a.id)) }
                }
                .labelsHidden()
                Button { addAnim() } label: { Image(systemName: "plus") }
                    .help("アニメを追加（マーク位置・セルの大きさで作成）")
                Button {
                    if let i = index {
                        editor.meta.anims.remove(at: i)
                        state.selectedAnimID = editor.meta.anims.first?.id
                    }
                } label: { Image(systemName: "minus") }
                    .disabled(index == nil)
            }

            if let i = index {
                editorFor($editor.meta.anims[i])
            } else {
                Text("＋ でアニメを追加します").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func addAnim() {
        let m = editor.meta
        var a = AnimDef(name: "アニメ \(m.anims.count + 1)", frameWidth: m.cellWidth, frameHeight: m.cellHeight)
        a.originX = m.mark.x
        a.originY = m.mark.y
        editor.meta.anims.append(a)
        state.selectedAnimID = a.id
    }

    @ViewBuilder
    private func editorFor(_ a: Binding<AnimDef>) -> some View {
        AnimPreviewRepresentable(state: state, playing: playing)
            .frame(minHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        HStack {
            Button { state.previewView?.step(-1) } label: { Image(systemName: "backward.frame") }
            Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
            Button { state.previewView?.step(1) } label: { Image(systemName: "forward.frame") }
            Spacer()
            Menu("書き出し") {
                ForEach(AnimExport.Format.allCases, id: \.self) { f in
                    Menu(f.label) {
                        ForEach([1, 2, 3, 4, 8], id: \.self) { s in
                            Button("\(s) 倍") { state.exportAnim(f, scale: s) }
                        }
                    }
                }
            }
            .fixedSize()
        }
        .buttonStyle(.borderless)

        Form {
            TextField("名前", text: a.name)
            Picker("種類", selection: a.mode) {
                Text("簡易").tag(AnimDef.Mode.grid)
                Text("登録").tag(AnimDef.Mode.list)
            }
            .pickerStyle(.segmented)
            LabeledContent("コマの大きさ") {
                HStack(spacing: 4) {
                    IntField(value: a.frameWidth, min: 1)
                    Text("×")
                    IntField(value: a.frameHeight, min: 1)
                    Button("セル") {
                        a.wrappedValue.frameWidth = editor.meta.cellWidth
                        a.wrappedValue.frameHeight = editor.meta.cellHeight
                    }
                    Button("ルーペ") {
                        a.wrappedValue.frameWidth = editor.meta.lupeWidth
                        a.wrappedValue.frameHeight = editor.meta.lupeHeight
                    }
                }
            }
            switch a.wrappedValue.mode {
            case .grid:
                LabeledContent("起点") {
                    HStack(spacing: 4) {
                        IntField(value: a.originX, min: 0)
                        Text(",")
                        IntField(value: a.originY, min: 0)
                        Button("マーク位置") {
                            a.wrappedValue.originX = editor.meta.mark.x
                            a.wrappedValue.originY = editor.meta.mark.y
                        }
                    }
                }
                LabeledContent("列 × 行") {
                    HStack(spacing: 4) {
                        IntField(value: a.columns, min: 1)
                        Text("×")
                        IntField(value: a.rows, min: 1)
                    }
                }
                LabeledContent("枚数") { IntField(value: a.count, min: 1) }
                LabeledContent("間隔") {
                    HStack(spacing: 4) {
                        IntField(value: a.interval, min: 10)
                        Text("ms")
                    }
                }
            case .list:
                LabeledContent("追加") {
                    HStack(spacing: 4) {
                        IntField(value: $newFrameDuration, min: 10)
                        Text("ms")
                        Button("マーク位置を追加") {
                            a.wrappedValue.frames.append(AnimFrame(x: editor.meta.mark.x, y: editor.meta.mark.y, duration: newFrameDuration))
                        }
                    }
                }
            }
        }
        .controlSize(.small)

        if a.wrappedValue.mode == .list {
            FrameList(frames: a.frames) { f in
                editor.setMark(IntPoint(f.x, f.y))
                state.stockView?.scrollMarkToVisible()
            }
        }
    }
}

struct FrameList: View {
    @Binding var frames: [AnimFrame]
    let jump: (AnimFrame) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(frames.enumerated()), id: \.element.id) { i, f in
                HStack(spacing: 6) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).frame(width: 20, alignment: .trailing)
                    Button("(\(f.x), \(f.y))") { jump(f) }
                        .buttonStyle(.link)
                        .font(.caption.monospacedDigit())
                        .help("マーク位置をこのコマへ")
                    Spacer()
                    IntField(value: $frames[i].duration, min: 10)
                    Text("ms").font(.caption)
                    Button { frames.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }
                        .disabled(i == 0)
                    Button { frames.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(i == frames.count - 1)
                    Button { frames.insert(AnimFrame(x: f.x, y: f.y, duration: f.duration), at: i + 1) } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .help("複製")
                    Button { frames.remove(at: i) } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            if frames.isEmpty {
                Text("マーク位置を動かしながら「マーク位置を追加」でコマを登録します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 整数の入力欄（範囲外は丸める）
struct IntField: View {
    @Binding var value: Int
    var min: Int = 0
    var max: Int = 8192

    var body: some View {
        TextField("", value: Binding(get: { value }, set: { value = Swift.min(Swift.max($0, min), max) }), format: .number.grouping(.never))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 48)
            .textFieldStyle(.roundedBorder)
    }
}

/// アニメウィンドウ
struct AnimWindow: View {
    let state: AppState

    var body: some View {
        ScrollView {
            AnimPanel(state: state, editor: state.editor)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 340, minHeight: 360)
        .onAppear { UserDefaults.standard.set(true, forKey: AnimWindow.openKey) }
        .onDisappear {
            if !AppDelegate.isTerminating { UserDefaults.standard.set(false, forKey: AnimWindow.openKey) }
        }
    }

    /// 開閉状態（既定は閉じる）
    static let openKey = "animWindowOpen"
}

// MARK: - 倍率

struct ZoomControls: View {
    let state: AppState
    @Bindable var editor: Editor

    private func percent(_ z: CGFloat) -> String {
        "\(Int((z * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("ストック").font(.caption.bold())
            Text(percent(state.stockZoom))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            Button { state.stockView?.stepZoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("縮小")
            Button { state.stockView?.stepZoom(1) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("拡大")
            Button("幅に合わせる") { state.stockView?.fitToView() }
                .help("シートの幅に合わせる (⌘0)")
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.bar)
    }
}

