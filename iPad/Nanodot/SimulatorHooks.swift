#if targetEnvironment(simulator)
import NanodotCore
import SwiftUI

/// 検証用の入口（シミュレーターだけ。実機・App Store のビルドには入らない）。
/// `xcrun simctl launch <端末> com.hashrock.nanodot <引数>` で渡す:
/// - `-open <パス>`: 書類を開く
/// - `-demo 1`: 歩くキャラの 3 コマと簡易アニメを描き、アニメのパネルを出す（オニオンスキンの確認用）
/// - `-demoSave 1`: `-demo` のあと「保存」する（書類フォルダーに PNG とサイドカーができる）
/// - `-layout WxH`: 画面をその大きさに切り詰めて並べる（横向き・Split View の幅の確認用）
/// - `-selftest 1`: メインのドットと画面座標の変換を確かめ、結果を tmp/selftest.txt に書く
/// - `-panel anim|settings|new`: そのパネル（アニメ・設定・新規シート）だけを画面いっぱいに出す（下のほうまで撮る確認用。
///   `-layout WxH` の幅も効く）。`-demoList 1` は `-demo` のアニメを「登録」にしてコマを 2 つ入れる
enum SimulatorHooks {
    static var panel: String? { UserDefaults.standard.string(forKey: "panel") }

    static var layoutSize: CGSize? {
        guard let s = UserDefaults.standard.string(forKey: "layout") else { return nil }
        let p = s.split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
    }

    static func run(_ state: PadState) {
        let d = UserDefaults.standard
        if d.bool(forKey: "demo") { demo(state) }
        if d.bool(forKey: "demoSave") { state.save() }
        if d.bool(forKey: "selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { selftest(state) }
        }
    }

    /// 16×16 のキャラを 3 コマ（左から）描く
    private static func demo(_ state: PadState) {
        let e = state.editor
        e.newDocument(width: 128, height: 64, cellWidth: 16, cellHeight: 16)
        state.documentName = "demo"
        let skin = RGBA(255, 204, 170), hair = RGBA(126, 37, 83), body = RGBA(41, 173, 255), dark = RGBA(29, 43, 83)
        for f in 0..<3 {
            let ox = f * 16
            e.performEdit("demo") {
                e.plot(Raster.rect(IntPoint(ox + 5, 2), IntPoint(ox + 10, 3), filled: true), color: hair, clip: e.image.bounds)
                e.plot(Raster.rect(IntPoint(ox + 5, 4), IntPoint(ox + 10, 7), filled: true), color: skin, clip: e.image.bounds)
                e.plot([IntPoint(ox + 6, 5), IntPoint(ox + 9, 5)], color: dark, clip: e.image.bounds)
                e.plot(Raster.rect(IntPoint(ox + 4, 8), IntPoint(ox + 11, 11), filled: true), color: body, clip: e.image.bounds)
                let legs: [(Int, Int)] = f == 1 ? [(6, 7), (8, 9)] : f == 0 ? [(5, 6), (9, 10)] : [(6, 6), (10, 10)]
                for (a, b) in legs {
                    e.plot(Raster.rect(IntPoint(ox + a, 12), IntPoint(ox + b, 14), filled: true), color: dark, clip: e.image.bounds)
                }
            }
        }
        e.meta.slots[0] = skin
        e.meta.slots[1] = hair
        e.meta.slots[2] = body
        e.meta.slots[3] = dark
        var a = AnimDef(name: "walk", frameWidth: 16, frameHeight: 16)
        a.columns = 3
        a.count = 3
        if UserDefaults.standard.bool(forKey: "demoList") {
            a.mode = .list
            a.frames = [AnimFrame(x: 0, y: 0, duration: 150), AnimFrame(x: 16, y: 0, duration: 200)]
        }
        e.meta.anims = [a]
        state.selectedAnimID = a.id
        e.setLupe(width: 16, height: 16)
        e.setMark(IntPoint(16, 0))
        e.color = body
        UserDefaults.standard.set(SidePanel.anim.rawValue, forKey: "pad.sidePanel")
        state.requestDisplay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { state.stockView?.fitToView() }
    }

    private static func selftest(_ state: PadState) {
        var lines: [String] = []
        if let v = state.mainView {
            lines.append(v.selfTest())
        } else {
            lines.append("NG: mainView がない") // l10n: 訳さない
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// `-panel` で出す、パネルだけの画面
struct SimulatorPanelPreview: View {
    let state: PadState
    let panel: String

    var body: some View {
        let width = SimulatorHooks.layoutSize?.width
        Group {
            switch panel {
            case "settings":
                SettingsPanel(state: state, editor: state.editor)
            case "new":
                NewDocumentSheet { _, _, _, _ in }
            default:
                ScrollView { AnimPanel(state: state, editor: state.editor).padding(12) }
            }
        }
        .frame(width: width)
        .border(Color.red)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension MainPadView {
    /// 画面上のドットの四隅の内側と中心の点を dot(at:) に通し、同じドットに戻るかを見る（ペン先とドットのずれがないこと）
    func selfTest() -> String {
        layoutIfNeeded()
        let m = editor.meta
        var bad = 0, total = 0
        for y in m.mark.y..<(m.mark.y + m.lupeHeight) {
            for x in m.mark.x..<(m.mark.x + m.lupeWidth) {
                let r = debugScreenRect(IntRect(x: x, y: y, width: 1, height: 1))
                let e: CGFloat = 0.01
                for p in [CGPoint(x: r.minX + e, y: r.minY + e), CGPoint(x: r.maxX - e, y: r.maxY - e), CGPoint(x: r.midX, y: r.midY)] {
                    total += 1
                    if debugDot(at: p) != IntPoint(x, y) { bad += 1 }
                }
            }
        }
        let z = zoom
        return "zoom=\(z) integer=\(z == z.rounded()) bounds=\(bounds.size) checked=\(total) mismatches=\(bad) " + (bad == 0 ? "OK" : "NG")
    }
}
#endif
