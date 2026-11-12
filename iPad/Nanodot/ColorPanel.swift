import NanodotCore
import SwiftUI
import UniformTypeIdentifiers

extension HSL {
    var color: Color { rgba(alpha: 255).swiftUIColor }
}

struct Swatch: View {
    let color: RGBA
    var selected = false
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            if color.a < 255 { CheckerBackground(size: size / 4) }
            Rectangle().fill(color.swiftUIColor)
        }
        .frame(width: size, height: size)
        .overlay {
            if selected {
                // どんな色の上でも見えるよう白黒の二重枠
                Rectangle().strokeBorder(Color.black, lineWidth: 3)
                Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
            }
        }
    }
}

/// 色のパネル: 描画色（RGB / HSL）、パレット、スロット
struct ColorPanel: View {
    let state: PadState
    @Bindable var editor: Editor

    private enum SwatchID: Hashable {
        case palette(Int)
        case slot(Int)
    }

    @State private var selected: SwatchID?
    /// スロットの範囲選択のもう一方の端
    @State private var rangeEnd: Int?
    /// パネルの幅に合わせた列数（4 の倍数）と色見本の大きさ
    @State private var columns = 8
    @State private var cell: CGFloat = 36
    private static let minCell: CGFloat = 30
    private static let maxCell: CGFloat = 44

    private var selectedRange: ClosedRange<Int>? {
        guard case .slot(let a) = selected, let e = rangeEnd, e != a else { return nil }
        return min(a, e)...max(a, e)
    }

    private func isSelected(_ id: SwatchID) -> Bool {
        if selected == id { return true }
        if case .slot(let i) = id, let r = selectedRange { return r.contains(i) }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PadColorEditor(editor: editor)
            Divider()
            palettes
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { fitGrid(to: g.size.width) }
                .onChange(of: g.size.width) { _, w in fitGrid(to: w) }
        })
    }

    private func fitGrid(to width: CGFloat) {
        let fit = Int(width / Self.minCell) / 4 * 4
        let cols = min(SheetMeta.slotCount, max(4, fit))
        columns = cols
        cell = max(Self.minCell, min(Self.maxCell, floor(width / CGFloat(cols))))
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(cell), spacing: 0), count: columns)
    }

    private func pick(_ id: SwatchID, _ c: RGBA) {
        selected = id
        rangeEnd = nil
        editor.color = c
        state.flashHighlight(c)
    }

    private var palettes: some View {
        VStack(alignment: .leading, spacing: 8) {
            let palette = SamplePalette.named(editor.meta.palette)
            Picker("パレット", selection: $editor.meta.palette) {
                ForEach(SamplePalette.all) { p in Text("\(LName(p.name))（\(p.colors.count) 色）").tag(p.name) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 0) {
                ForEach(Array(palette.colors.enumerated()), id: \.offset) { i, c in
                    Swatch(color: c, selected: isSelected(.palette(i)), size: cell)
                        .onTapGesture { pick(.palette(i), c) }
                        .draggable(c.hex) { Swatch(color: c, size: cell) }
                        .contextMenu { colorMenu(c) }
                        .accessibilityLabel(c.hex)
                }
            }

            HStack {
                Text("スロット").font(.subheadline.bold())
                if state.isOutsideDocument {
                    Text("（この書類には保存されません）").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    slotsMenu
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 30, height: 30)
                }
                .accessibilityLabel("スロットの操作")
            }
            .padding(.top, 2)
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 0) {
                ForEach(0..<SheetMeta.slotCount, id: \.self) { i in slot(i) }
            }
            if selectedRange != nil {
                rangeBar
            } else {
                slotEditBar
            }
            Text("長押しで操作、ドラッグでスロットへ移す")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 選択中のスロットが空きなら登録、色と描画色が違えば反映する操作を出す
    @ViewBuilder
    private var slotEditBar: some View {
        if case .slot(let i) = selected, editor.meta.slots[i] == nil {
            HStack(spacing: 8) {
                Swatch(color: editor.color, size: 22)
                Button("スロット \(i + 1) に登録") { editor.meta.slots[i] = editor.color }
                    .keyboardShortcut(.return, modifiers: [.command])
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        } else if case .slot(let i) = selected, let old = editor.meta.slots[i], old != editor.color {
            HStack(spacing: 8) {
                Swatch(color: old, size: 22)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Swatch(color: editor.color, size: 22)
                Button("スロットに反映") { editor.meta.slots[i] = editor.color }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button("戻す") { editor.color = old }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var rangeBar: some View {
        if let r = selectedRange {
            HStack(spacing: 10) {
                Text("\(r.count) 個").font(.callout)
                rangeButtons(r)
                Spacer(minLength: 0)
                Button { rangeEnd = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("範囲選択をやめる")
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
        .disabled(!canGradient)
        Button("反転") { editor.meta.slots = SlotOps.reversed(slots, r.lowerBound, r.upperBound) }
        Button("消去", role: .destructive) {
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
        Button("すべてのスロットを消去", role: .destructive) {
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

    /// スロットの範囲選択: 選んでいるスロットからここまで
    @ViewBuilder
    private func rangeMenuItem(_ i: Int) -> some View {
        if case .slot(let a) = selected, a != i {
            Button("スロット \(a + 1) からここまでを選ぶ") { rangeEnd = i }
        }
    }

    /// ドロップされた色（hex）。スロットから来たものは "slot:番号" で、入れ替えにする
    private func drop(_ items: [String], on i: Int) -> Bool {
        guard let s = items.first else { return false }
        if s.hasPrefix("slot:"), let from = Int(s.dropFirst(5)) {
            editor.meta.slots = SlotOps.move(editor.meta.slots, from: from, to: i, copy: false)
        } else if let c = RGBA(hex: s) {
            editor.meta.slots[i] = c
        } else {
            return false
        }
        selected = .slot(i)
        rangeEnd = nil
        return true
    }

    @ViewBuilder
    private func slot(_ i: Int) -> some View {
        Group {
            if let c = editor.meta.slots[i] {
                Swatch(color: c, selected: isSelected(.slot(i)), size: cell)
                    .onTapGesture { pick(.slot(i), c) }
                    .draggable("slot:\(i)") { Swatch(color: c, size: cell) }
                    .contextMenu {
                        if let r = selectedRange, r.contains(i) {
                            rangeButtons(r)
                            Divider()
                        }
                        rangeMenuItem(i)
                        Button("描画色で上書き") { editor.meta.slots[i] = editor.color }
                        Button("消去", role: .destructive) { editor.meta.slots[i] = nil }
                        Divider()
                        replaceMenu(c)
                    }
                    .accessibilityLabel(c.hex)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(isSelected(.slot(i)) ? 0.35 : 0.1))
                    .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    .frame(width: cell, height: cell)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selected = .slot(i)
                        rangeEnd = nil
                    }
                    .contextMenu {
                        rangeMenuItem(i)
                        Button("描画色を登録") { editor.meta.slots[i] = editor.color }
                    }
                    .accessibilityLabel("空きスロット \(i + 1)")
            }
        }
        .dropDestination(for: String.self) { items, _ in drop(items, on: i) }
    }
}

/// 描画色の RGB / HSL エディター（指で動かしやすいよう太めのスライダー）
struct PadColorEditor: View {
    @Bindable var editor: Editor
    @AppStorage("colorEditorMode") private var mode = "rgb"
    /// HSL は無彩色で色相が失われるので、自前で持っておく
    @State private var hsl = HSL(h: 0, s: 0, l: 0)
    @State private var lastSet: RGBA?
    @State private var hexText = ""

    private var c: RGBA { editor.color }

    private func set(_ new: RGBA) {
        lastSet = new
        editor.color = new
    }

    private func setHSL(_ h: HSL) {
        hsl = h
        set(h.rgba(alpha: c.a))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Swatch(color: c, size: 36)
                    .draggable(c.hex) { Swatch(color: c, size: 36) }
                    .accessibilityLabel("描画色")
                Picker("", selection: $mode) {
                    Text("RGB").tag("rgb")
                    Text("HSL").tag("hsl")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
                TextField("", text: $hexText)
                    .font(.callout.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(width: 96)
                    .onSubmit {
                        if let v = RGBA(hex: hexText) { set(v) } else { hexText = hexString(c) }
                    }
                    .accessibilityLabel("16 進数（rrggbb または rrggbbaa）")
                Spacer(minLength: 0)
                Button { set(.clear) } label: { Swatch(color: .clear, selected: c.a == 0, size: 28) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("透明")
            }

            if mode == "rgb" {
                ChannelSlider(label: "R", value: channel(\.r), max: 255,
                              colors: [RGBA(0, c.g, c.b).swiftUIColor, RGBA(255, c.g, c.b).swiftUIColor])
                ChannelSlider(label: "G", value: channel(\.g), max: 255,
                              colors: [RGBA(c.r, 0, c.b).swiftUIColor, RGBA(c.r, 255, c.b).swiftUIColor])
                ChannelSlider(label: "B", value: channel(\.b), max: 255,
                              colors: [RGBA(c.r, c.g, 0).swiftUIColor, RGBA(c.r, c.g, 255).swiftUIColor])
            } else {
                ChannelSlider(label: "H", value: Binding(get: { hsl.h / 360 }, set: { var h = hsl; h.h = min($0 * 360, 359.999); setHSL(h) }),
                              max: 360, colors: stride(from: 0.0, through: 360, by: 30).map { HSL(h: $0, s: hsl.s, l: hsl.l).color })
                ChannelSlider(label: "S", value: Binding(get: { hsl.s }, set: { var h = hsl; h.s = $0; setHSL(h) }),
                              max: 100, colors: [HSL(h: hsl.h, s: 0, l: hsl.l).color, HSL(h: hsl.h, s: 1, l: hsl.l).color])
                ChannelSlider(label: "L", value: Binding(get: { hsl.l }, set: { var h = hsl; h.l = $0; setHSL(h) }),
                              max: 100, colors: [.black, HSL(h: hsl.h, s: hsl.s, l: 0.5).color, .white])
            }
            ChannelSlider(label: "A", value: channel(\.a), max: 255, checker: true,
                          colors: [RGBA(c.r, c.g, c.b, 0).swiftUIColor, RGBA(c.r, c.g, c.b, 255).swiftUIColor])
        }
        .onAppear {
            hsl = HSL(c)
            hexText = hexString(c)
        }
        .onChange(of: editor.color) { _, new in
            if new != lastSet { hsl = HSL(new) }
            hexText = hexString(new)
        }
    }

    private func hexString(_ v: RGBA) -> String { String(v.hex.dropFirst()) }

    private func channel(_ kp: WritableKeyPath<RGBA, UInt8>) -> Binding<Double> {
        Binding(get: { Double(c[keyPath: kp]) / 255 }, set: { v in
            var n = c
            n[keyPath: kp] = UInt8(max(0, min(255, (v * 255).rounded())))
            if kp == \RGBA.a { set(n) } else { editor.color = n }
        })
    }
}

/// グラデーションの帯と数値のスライダー（value: 0〜1、表示は 0〜max）
struct ChannelSlider: View {
    let label: String
    @Binding var value: Double
    let max: Int
    var checker = false
    let colors: [Color]

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 14)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    if checker { CheckerBackground(size: 6) }
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white, lineWidth: 3)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.6), lineWidth: 4))
                        .frame(width: 14)
                        .offset(x: value * (w - 14))
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    value = Swift.min(1, Swift.max(0, (g.location.x - 7) / Swift.max(1, w - 14)))
                })
            }
            .frame(height: 26)
            Text("\(Int((value * Double(max)).rounded()))")
                .font(.callout.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
    }
}
