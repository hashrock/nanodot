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
/// - `-eyedropperTest 1`: スポイトのツールで、色のあるドット・透明のドット・シートの外を拾い、結果を tmp/eyedropper.txt に書く。
///   終わったらスポイトを選んだままにする（ツールバーの確認用）。`-demo 1` と一緒に使う
/// - `-selectTest 1`: 選択のツールで範囲を選び、動かす・確定・取り消す・キャンセルを確かめ、結果を tmp/select.txt に書く。
///   終わったら中身を動かして浮かせたままにする（確定・キャンセルのボタンの確認用）。`-demo 1` と一緒に使う
/// - `-demoMap 1`: `-demo` の絵に草・石のセルを足し、マップ（2 レイヤー）を作ってマップの画面を出す。`-demo 1` と一緒に使う
/// - `-mapTest 1`: マップのタイルと画面座標の変換と、置く・拾う・取り消しを確かめ、結果を tmp/maptest.txt に書く。`-demoMap 1` と一緒に使う
/// - `-panel anim|settings|new|map`: そのパネル（アニメ・設定・新規シート）だけを画面いっぱいに出す（下のほうまで撮る確認用。
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
        if d.bool(forKey: "demoMap") { demoMap(state) }
        if d.bool(forKey: "demoSave") { state.save() }
        if d.bool(forKey: "mapTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { mapTest(state) }
        }
        if d.bool(forKey: "selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { selftest(state) }
        }
        if d.bool(forKey: "eyedropperTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { eyedropperTest(state) }
        }
        if d.bool(forKey: "selectTest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { selectTest(state) }
        }
    }

    /// 選択範囲: `-demo` の 2 コマ目（マーク (16, 0)）の頭を選んで動かす
    private static func selectTest(_ state: PadState) {
        let e = state.editor
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool) { lines.append("\(ok ? "ok" : "NG") \(name)") }
        let hair = e.image[21, 2]
        e.tool = .select
        e.setSelection(IntRect(x: 21, y: 2, width: 6, height: 2))
        check("selected", e.selection == IntRect(x: 21, y: 2, width: 6, height: 2))
        e.beginMoveSelection()
        e.moveSelection(dx: 0, dy: 10)
        e.endMoveSelection()
        check("floating", e.isFloating && e.image[21, 12] == hair && e.image[21, 2].a == 0)
        e.commitSelection()
        check("committed", !e.isFloating && e.undoLabel == L("移動"))
        e.undo()
        check("undo", e.image[21, 2] == hair && e.selection == nil)
        e.setSelection(IntRect(x: 20, y: 2, width: 8, height: 6))
        check("can rotate non-square", e.canRotate)
        e.nudgeSelection(dx: 0, dy: 4)
        e.cancelSelection()
        check("cancel", !e.isFloating && e.image[21, 2] == hair && e.selection == IntRect(x: 20, y: 2, width: 8, height: 6))
        e.nudgeSelection(dx: 0, dy: 4)
        state.mainView?.setNeedsDisplay()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("select.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
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

    /// 草（セル 3）と石（セル 4）を描き、20×12 のマップに並べる。石は通行不可
    private static func demoMap(_ state: PadState) {
        let e = state.editor
        let grass = RGBA(0, 168, 68), grass2 = RGBA(0, 135, 81), stone = RGBA(131, 118, 156), stone2 = RGBA(95, 87, 79)
        e.performEdit("demo") {
            e.plot(Raster.rect(IntPoint(48, 0), IntPoint(63, 15), filled: true), color: grass, clip: e.image.bounds)
            e.plot([IntPoint(51, 3), IntPoint(57, 5), IntPoint(53, 10), IntPoint(60, 12), IntPoint(49, 13)], color: grass2, clip: e.image.bounds)
            e.plot(Raster.rect(IntPoint(64, 0), IntPoint(79, 15), filled: true), color: stone, clip: e.image.bounds)
            e.plot(Raster.rect(IntPoint(64, 7), IntPoint(79, 7), filled: true) + Raster.rect(IntPoint(71, 0), IntPoint(71, 7), filled: true)
                   + Raster.rect(IntPoint(67, 8), IntPoint(67, 15), filled: true) + Raster.rect(IntPoint(75, 8), IntPoint(75, 15), filled: true),
                   color: stone2, clip: e.image.bounds)
        }
        var a = e.meta.annotation(col: 4, row: 0)
        a.passable = false
        e.meta.setAnnotation(a)
        var m = TileMapDef(name: "village", width: 20, height: 12)
        for y in 0..<12 { for x in 0..<20 { m.set(0, x, y, 3) } }
        for x in 0..<20 { m.set(0, x, 0, 4); m.set(0, x, 11, 4) }
        for y in 0..<12 { m.set(0, 0, y, 4); m.set(0, 19, y, 4) }
        for x in 6..<14 { m.set(0, x, 6, 4) }
        m.set(1, 4, 4, 0)
        m.set(1, 9, 3, 1)
        m.set(1, 15, 8, 2)
        e.meta.maps = [m]
        state.mapSession.sheetReplaced()
        state.mapSession.layer = 1
        e.setMark(IntPoint(16, 0))
        state.mapMode = true
        state.requestDisplay()
    }

    /// マップ: タイルの四隅と中心が同じタイルに戻るか、置く・取り消し・拾うが効くか
    private static func mapTest(_ state: PadState) {
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool) { lines.append("\(ok ? "OK" : "NG") \(name)") }
        let s = state.mapSession
        if let v = state.mapView, let m = s.map {
            v.layoutIfNeeded()
            var bad = 0
            for y in 0..<m.height {
                for x in 0..<m.width {
                    let r = v.debugTileRect(x, y)
                    for p in [CGPoint(x: r.minX + 0.01, y: r.minY + 0.01), CGPoint(x: r.maxX - 0.01, y: r.maxY - 0.01), CGPoint(x: r.midX, y: r.midY)]
                    where v.debugTile(at: p) != IntPoint(x, y) { bad += 1 }
                }
            }
            check("tile <-> screen (zoom \(v.zoomPercent)%)", bad == 0)
        } else {
            check("mapView", false)
        }
        let before = s.map?.tile(1, 10, 9)
        let sheetUndo = state.editor.undoLabel
        s.tool = .pen
        s.beginEdit()
        s.apply(at: IntPoint(10, 9))
        check("pen places mark brush", s.map?.tile(1, 10, 9) == 1)
        state.undo()
        check("undo goes to map history", s.map?.tile(1, 10, 9) == before && state.editor.undoLabel == sheetUndo && state.editor.canRedo == false)
        state.redo()
        check("redo", s.map?.tile(1, 10, 9) == 1)
        s.layer = 0
        s.pickTile(at: IntPoint(0, 0))
        check("pick stone", s.brush == .single(4))
        s.brushOverride = nil
        s.layer = 1
        state.mapView?.setNeedsDisplay()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maptest.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// demo の絵（16, 0 からのコマ）で確かめる。(16+5, 8) は体の色、(16, 0) は透明
    private static func eyedropperTest(_ state: PadState) {
        let e = state.editor
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool) { lines.append((ok ? "OK " : "NG ") + name) }
        e.tool = .rect
        e.color = RGBA(1, 2, 3)
        state.setEyedropper(true)
        check("active after select", state.eyedropperActive && !e.stampActive)
        check("outside sheet is ignored", !state.finishEyedropper(at: IntPoint(-1, -1)) && state.eyedropperActive && e.color == RGBA(1, 2, 3))
        let body = e.image[21, 8]
        check("pick opaque \(body)", state.finishEyedropper(at: IntPoint(21, 8)) && e.color == body && body.a == 255)
        check("back to previous tool", !state.eyedropperActive && e.tool == .rect)
        state.setEyedropper(true)
        check("pick transparent", state.finishEyedropper(at: IntPoint(16, 0)) && e.color.a == 0 && !state.eyedropperActive)
        e.stampActive = true
        state.setEyedropper(true)
        check("eyedropper ends stamp mode", !e.stampActive)
        state.setEyedropper(false)
        check("toggle off keeps tool", !state.eyedropperActive && e.tool == .rect)
        // 確認の画面用: 体の色を拾い直し、スポイトを選んだままにする
        _ = state.finishEyedropper(at: IntPoint(21, 8))
        state.setEyedropper(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eyedropper.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
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
            case "map":
                ScrollView { MapPanel(state: state, editor: state.editor).padding(12) }
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
