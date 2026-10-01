import NanodotCore
import SwiftUI

extension HSL {
    var color: Color { rgba(alpha: 255).swiftUIColor }
}

/// 描画色の RGB / HSL エディター
struct ColorEditor: View {
    @Bindable var editor: Editor
    /// プレビューの色見本に付けるジェスチャー（スロットへのドラッグ）
    var previewGesture: AnyGesture<Void>?
    @AppStorage("colorEditorMode") private var mode = "rgb"
    /// HSL は無彩色で色相が失われるので、自前で持っておく
    @State private var hsl = HSL(h: 0, s: 0, l: 0)
    /// 自分で設定した色（外から変わったときだけ HSL を作り直す）
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Swatch(color: c, size: 36)
                    .gesture(previewGesture ?? AnyGesture(TapGesture().map { _ in () }))
                    .help("ドラッグでスロットに登録")
                Picker("", selection: $mode) {
                    Text("RGB").tag("rgb")
                    Text("HSL").tag("hsl")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
                Spacer()
                Button { set(.clear) } label: { Swatch(color: .clear, selected: c.a == 0) }
                    .buttonStyle(.plain)
                    .help("透明")
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

            HStack(spacing: 4) {
                Text("#").font(.caption.monospaced()).foregroundStyle(.secondary)
                TextField("", text: $hexText)
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit {
                        if let v = RGBA(hex: hexText) { set(v) } else { hexText = hexString(c) }
                    }
                Spacer()
            }
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

    private func hexString(_ v: RGBA) -> String {
        String(v.hex.dropFirst())
    }

    private func channel(_ kp: WritableKeyPath<RGBA, UInt8>) -> Binding<Double> {
        Binding(get: { Double(c[keyPath: kp]) / 255 }, set: { v in
            var n = c
            n[keyPath: kp] = UInt8(max(0, min(255, (v * 255).rounded())))
            // RGB を変えたら HSL も作り直す（A だけなら色相を保つ）
            if kp == \RGBA.a { set(n) } else { editor.color = n }
        })
    }
}

/// グラデーションの帯と数値欄のスライダー（value: 0〜1、表示は 0〜max）
struct ChannelSlider: View {
    let label: String
    @Binding var value: Double
    let max: Int
    var checker = false
    let colors: [Color]

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 12)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    if checker { CheckerBackground(size: 4) }
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.black.opacity(0.2))
                    // つまみ
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.white, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.6), lineWidth: 3))
                        .frame(width: 8)
                        .offset(x: value * (w - 8))
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    value = Swift.min(1, Swift.max(0, (g.location.x - 4) / Swift.max(1, w - 8)))
                })
            }
            .frame(height: 16)
            IntField(value: Binding(get: { Int((value * Double(max)).rounded()) },
                                    set: { value = Double($0) / Double(max) }), min: 0, max: max)
        }
    }
}
