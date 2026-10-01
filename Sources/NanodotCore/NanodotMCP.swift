import Foundation

/// MCP のツールから見たアプリ側
public protocol MCPHost: AnyObject {
    var editor: Editor { get }
    /// 開く・新規でシートが入れ替わったとき（表示の調整など）
    func sheetReplaced()
}

/// nanodot を操作する MCP ツール一式
public enum NanodotMCP {
    public static let instructions = """
    nanodot はスプライトシート（小さな絵が格子状に並んだ PNG）用のドット絵エディターです。
    座標はシート左上が (0, 0) のドット単位。色は "#rrggbb" / "#rrggbbaa" / "transparent"。
    シートはセル（cell_width × cell_height）で区切られ、マップのタイルはセル番号（行 × sheet_columns + 列、空は -1）で表します。
    まず get_sheet_info で大きさを、get_image で見た目を確かめてから編集してください。
    描画（set_pixels / draw_shape / fill / fill_rect / draw_text / copy_region / replace_color）は 1 回の呼び出しが 1 回の取り消し単位です。
    注釈・アニメ・マップ・スロットの変更は取り消しの対象外です。保存は save_sheet で明示的に行います。
    """

    public static func server(host: MCPHost, version: String) -> MCPServer {
        MCPServer(name: "nanodot", version: version, instructions: instructions, tools: tools(host))
    }

    // MARK: - スキーマの部品

    static func prop(_ type: String, _ desc: String) -> [String: Any] { ["type": type, "description": desc] }
    static let colorProp = prop("string", "色。#rrggbb / #rrggbbaa / transparent")
    static let regionProps: [String: [String: Any]] = [
        "x": prop("integer", "左上の x（省略時 0）"),
        "y": prop("integer", "左上の y（省略時 0）"),
        "width": prop("integer", "幅（省略時はシートの右端まで）"),
        "height": prop("integer", "高さ（省略時はシートの下端まで）"),
    ]

    static func region(_ a: MCPArgs, _ e: Editor) -> IntRect {
        let x = a.optInt("x") ?? 0, y = a.optInt("y") ?? 0
        let w = a.optInt("width") ?? (e.image.width - x), h = a.optInt("height") ?? (e.image.height - y)
        return IntRect(x: x, y: y, width: w, height: h)
    }

    static func checkedRegion(_ a: MCPArgs, _ e: Editor, maxPixels: Int) throws -> IntRect {
        let r = region(a, e).intersection(e.image.bounds)
        guard !r.isEmpty else { throw MCPError("範囲がシートの外です（シートは \(e.image.width)×\(e.image.height)）") }
        guard r.width * r.height <= maxPixels else { throw MCPError("範囲が大きすぎます（最大 \(maxPixels) ドット）。小さく分けてください") }
        return r
    }

    static func sheetInfo(_ e: Editor) -> [String: Any] {
        let m = e.meta
        return [
            "width": e.image.width, "height": e.image.height,
            "cell_width": m.cellWidth, "cell_height": m.cellHeight,
            "sheet_columns": max(1, e.image.width / max(1, m.cellWidth)),
            "sheet_rows": max(1, e.image.height / max(1, m.cellHeight)),
            "mark": ["x": m.mark.x, "y": m.mark.y, "width": m.lupeWidth, "height": m.lupeHeight],
            "drawing_color": e.color.hex,
            "palette": m.palette,
            "file": e.fileURL?.path ?? NSNull(),
            "unsaved_changes": e.isDirty,
            "anims": m.anims.count, "maps": m.maps.count, "annotations": m.annotations.count,
            "can_undo": e.canUndo, "can_redo": e.canRedo,
        ]
    }

    static func findMap(_ a: MCPArgs, _ e: Editor) throws -> Int {
        let maps = e.meta.maps
        if let i = a.optInt("map"), maps.indices.contains(i) { return i }
        if let n = a.optString("map"), let i = maps.firstIndex(where: { $0.name == n }) { return i }
        guard !maps.isEmpty else { throw MCPError("マップがありません。create_map で作ってください") }
        if !a.has("map") { return 0 }
        throw MCPError("マップ \(a.values["map"] ?? "") が見つかりません（名前か番号）")
    }

    // MARK: - ツール

    static func tools(_ host: MCPHost) -> [MCPTool] {
        var e: Editor { host.editor }
        return [
            MCPTool("get_sheet_info", "シートの大きさ・セル・マーク範囲・描画色・保存状態などを返す") { _ in
                .json(sheetInfo(e))
            },

            MCPTool("get_image", "シート（または範囲）を拡大した PNG 画像で返す。見た目の確認用", properties: regionProps.merging([
                "scale": prop("integer", "拡大率 1〜16（省略時は長辺が 512px 前後になる倍率）"),
            ]) { a, _ in a }) { a in
                let r = try checkedRegion(a, e, maxPixels: 1_048_576)
                let auto = max(1, min(16, 512 / max(r.width, r.height)))
                var scale = max(1, min(16, a.optInt("scale") ?? auto))
                while max(r.width, r.height) * scale > 2048 && scale > 1 { scale -= 1 }
                guard let png = SheetFile.pngData(e.image.copy(r).scaled(scale)) else { throw MCPError("画像を作れませんでした") }
                return .image(png: png, caption: "範囲 x=\(r.x) y=\(r.y) \(r.width)×\(r.height)、\(scale) 倍")
            },

            MCPTool("get_pixels", "範囲の画素を返す。palette（色の一覧）と rows（各行の palette 番号を空白区切り）の形式。最大 128×128",
                    properties: regionProps) { a in
                let r = try checkedRegion(a, e, maxPixels: 128 * 128)
                var palette: [RGBA] = []
                var index: [RGBA: Int] = [:]
                var rows: [String] = []
                for y in r.y..<r.maxY {
                    var row: [String] = []
                    for x in r.x..<r.maxX {
                        let c = e.image[x, y]
                        let i = index[c] ?? { palette.append(c); index[c] = palette.count - 1; return palette.count - 1 }()
                        row.append(String(i))
                    }
                    rows.append(row.joined(separator: " "))
                }
                return .json(["x": r.x, "y": r.y, "width": r.width, "height": r.height, "palette": palette.map(\.hex), "rows": rows])
            },

            MCPTool("set_pixels", """
            画素を置く。次のどちらかで指定する:
            (1) pixels: [{x, y, color}]
            (2) x, y, palette, rows: get_pixels と同じ形式。rows の各要素は palette 番号の空白区切りで、"." はその画素を変えない
            """, properties: [
                "pixels": ["type": "array", "description": "[{x, y, color}]", "items": ["type": "object"]],
                "x": prop("integer", "(2) の左上 x"), "y": prop("integer", "(2) の左上 y"),
                "palette": ["type": "array", "items": ["type": "string"], "description": "(2) の色の一覧"],
                "rows": ["type": "array", "items": ["type": "string"], "description": "(2) の行"],
            ]) { a in
                var px: [(IntPoint, RGBA)] = []
                if let list = a.array("pixels") as? [[String: Any]] {
                    for item in list {
                        let p = MCPArgs(item)
                        px.append((IntPoint(try p.int("x"), try p.int("y")), try p.color("color")))
                    }
                } else if let rows = a.array("rows") as? [String] {
                    let pal = try (a.array("palette") as? [String] ?? []).map(MCPArgs.parseColor)
                    let ox = try a.int("x"), oy = try a.int("y")
                    for (dy, row) in rows.enumerated() {
                        for (dx, tok) in row.split(separator: " ").enumerated() where tok != "." {
                            guard let i = Int(tok), pal.indices.contains(i) else { throw MCPError("rows[\(dy)] の \(tok) は palette にありません") }
                            px.append((IntPoint(ox + dx, oy + dy), pal[i]))
                        }
                    }
                } else {
                    throw MCPError("pixels か rows を指定してください")
                }
                guard px.count <= 65_536 else { throw MCPError("一度に置けるのは 65536 ドットまでです") }
                e.performEdit("MCP: 画素") { e.setPixels(px, clip: e.image.bounds) }
                return .text("\(px.count) ドットを置きました")
            },

            MCPTool("draw_shape", "直線・矩形・楕円を描く（両端を含む 2 点で指定）", properties: [
                "shape": ["type": "string", "enum": ["line", "rect", "ellipse"], "description": "図形"],
                "x1": prop("integer", "始点 x"), "y1": prop("integer", "始点 y"),
                "x2": prop("integer", "終点 x"), "y2": prop("integer", "終点 y"),
                "color": colorProp, "filled": prop("boolean", "矩形・楕円を塗りつぶす"),
            ], required: ["shape", "x1", "y1", "x2", "y2", "color"]) { a in
                let tool: Tool
                switch try a.string("shape") {
                case "line": tool = .line
                case "rect": tool = .rect
                case "ellipse": tool = .ellipse
                case let s: throw MCPError("shape \(s) は line / rect / ellipse のどれかです")
                }
                e.drawShape(tool, from: IntPoint(try a.int("x1"), try a.int("y1")), to: IntPoint(try a.int("x2"), try a.int("y2")),
                            filled: a.optBool("filled") ?? false, color: try a.color("color"), clip: e.image.bounds)
                return .text("描きました")
            },

            MCPTool("fill", "(x, y) とつながった同じ色の範囲を塗りつぶす（4 近傍）", properties: [
                "x": prop("integer", "x"), "y": prop("integer", "y"), "color": colorProp,
                "region": ["type": "object", "description": "塗る範囲を {x, y, width, height} に限る（省略時はシート全体）"],
            ], required: ["x", "y", "color"]) { a in
                let clip = (a.values["region"] as? [String: Any]).map { region(MCPArgs($0), e) } ?? e.image.bounds
                e.floodFill(at: IntPoint(try a.int("x"), try a.int("y")), color: try a.color("color"), clip: clip)
                return .text("塗りつぶしました")
            },

            MCPTool("fill_rect", "範囲を 1 色で塗る（transparent で消去）", properties: regionProps.merging(["color": colorProp]) { a, _ in a },
                    required: ["x", "y", "width", "height", "color"]) { a in
                let r = try checkedRegion(a, e, maxPixels: 16_777_216)
                let c = try a.color("color")
                e.performEdit("MCP: 塗り") { e.pasteBuffer(PixelBuffer(width: r.width, height: r.height, fill: c), at: r.origin, skipTransparent: false) }
                return .text("x=\(r.x) y=\(r.y) \(r.width)×\(r.height) を塗りました")
            },

            MCPTool("draw_text", "文字を描く（アンチエイリアスなしのドット）。(x, y) が文字の左上", properties: [
                "x": prop("integer", "左上 x"), "y": prop("integer", "左上 y"),
                "text": prop("string", "文字（改行可）"), "color": colorProp,
                "size": prop("number", "大きさ（pt、省略時 12）"),
                "font": prop("string", "フォントの PostScript 名（省略時 system。例: HiraginoSans-W3, Menlo-Regular）"),
                "antialias": prop("boolean", "縁をなめらかにする（半透明の画素ができる）"),
            ], required: ["x", "y", "text", "color"]) { a in
                var s = TextSettings()
                s.size = a.optDouble("size") ?? 12
                s.fontName = a.optString("font") ?? "system"
                s.antialias = a.optBool("antialias") ?? false
                let r = e.drawText(try a.string("text"), at: IntPoint(try a.int("x"), try a.int("y")), settings: s,
                                   color: try a.color("color"), clip: e.image.bounds)
                return .text(r.isEmpty ? "描ける範囲がありませんでした" : "x=\(r.x) y=\(r.y) \(r.width)×\(r.height) に描きました")
            },

            MCPTool("copy_region", "範囲を別の場所に写す。transform で反転・回転してから写せる", properties: regionProps.merging([
                "dest_x": prop("integer", "写し先の左上 x"), "dest_y": prop("integer", "写し先の左上 y"),
                "transform": ["type": "string", "enum": ["none", "flip_h", "flip_v", "rotate_cw", "rotate_ccw"], "description": "変形"],
                "skip_transparent": prop("boolean", "透明な画素は写さない（省略時 false = 上書き）"),
            ]) { a, _ in a }, required: ["x", "y", "width", "height", "dest_x", "dest_y"]) { a in
                let r = try checkedRegion(a, e, maxPixels: 16_777_216)
                var buf = e.image.copy(r)
                switch a.optString("transform") ?? "none" {
                case "flip_h": buf = buf.flippedHorizontally()
                case "flip_v": buf = buf.flippedVertically()
                case "rotate_cw": buf = buf.rotatedClockwise()
                case "rotate_ccw": buf = buf.rotatedCounterClockwise()
                default: break
                }
                let d = IntPoint(try a.int("dest_x"), try a.int("dest_y"))
                e.performEdit("MCP: 写す") { e.pasteBuffer(buf, at: d, skipTransparent: a.optBool("skip_transparent") ?? false) }
                return .text("\(buf.width)×\(buf.height) を (\(d.x), \(d.y)) に写しました")
            },

            MCPTool("replace_color", "シート全体で、ある色を別の色に置き換える", properties: [
                "from": colorProp, "to": colorProp,
            ], required: ["from", "to"]) { a in
                e.replaceColor(try a.color("from"), with: try a.color("to"), inMarkOnly: false)
                return .text("置き換えました")
            },

            MCPTool("set_mark", "メインに表示する範囲（マーク位置とルーペの大きさ）を変える", properties: [
                "x": prop("integer", "左上 x"), "y": prop("integer", "左上 y"),
                "width": prop("integer", "幅（省略時はそのまま）"), "height": prop("integer", "高さ（省略時はそのまま）"),
            ], required: ["x", "y"]) { a in
                if a.has("width") || a.has("height") {
                    e.setLupe(width: a.optInt("width") ?? e.meta.lupeWidth, height: a.optInt("height") ?? e.meta.lupeHeight)
                }
                e.setMark(IntPoint(try a.int("x"), try a.int("y")))
                return .json(sheetInfo(e)["mark"] as Any)
            },

            MCPTool("set_drawing_color", "アプリの描画色を変える", properties: ["color": colorProp], required: ["color"]) { a in
                e.color = try a.color("color")
                return .text("描画色を \(e.color.hex) にしました")
            },

            MCPTool("undo", "直前の描画を取り消す") { _ in
                guard e.canUndo else { return .text("取り消せる操作がありません") }
                let l = e.undoLabel ?? ""
                e.undo()
                return .text("取り消しました: \(l)")
            },

            MCPTool("redo", "取り消した描画をやり直す") { _ in
                guard e.canRedo else { return .text("やり直せる操作がありません") }
                let l = e.redoLabel ?? ""
                e.redo()
                return .text("やり直しました: \(l)")
            },

            // MARK: パレット

            MCPTool("get_palette", "選んでいるパレット・スロット・描画色を返す") { _ in
                .json([
                    "palette": e.meta.palette,
                    "palette_colors": SamplePalette.named(e.meta.palette).colors.map(\.hex),
                    "available_palettes": SamplePalette.all.map(\.name),
                    "slots": e.meta.slots.map { $0?.hex ?? NSNull() as Any },
                    "drawing_color": e.color.hex,
                ])
            },

            MCPTool("set_palette", "サンプルパレットを選ぶ・スロットに色を置く", properties: [
                "palette": prop("string", "サンプルパレットの名前（get_palette の available_palettes）"),
                "slots": ["type": "array", "description": "start から順に置く色（null で空にする）", "items": ["type": ["string", "null"]]],
                "start": prop("integer", "slots を置き始める番号（0〜63、省略時 0）"),
            ]) { a in
                if let p = a.optString("palette") {
                    guard SamplePalette.all.contains(where: { $0.name == p }) else { throw MCPError("パレット \(p) はありません") }
                    e.meta.palette = p
                }
                if let list = a.array("slots") {
                    let start = a.optInt("start") ?? 0
                    var slots = e.meta.slots
                    for (i, v) in list.enumerated() where slots.indices.contains(start + i) {
                        slots[start + i] = try (v as? String).map(MCPArgs.parseColor)
                    }
                    e.meta.slots = slots
                }
                return .text("更新しました")
            },

            // MARK: 注釈

            MCPTool("list_annotations", "設定のあるセルの注釈（名前・通行可否・重なり順）を返す") { _ in
                .json(e.meta.annotations.map { ["col": $0.col, "row": $0.row, "name": $0.name, "passable": $0.passable, "z": $0.z] })
            },

            MCPTool("set_annotation", "セルの注釈を設定する。省略した項目はそのまま。すべて既定値（名前なし・通行可・z=0）にすると消える", properties: [
                "col": prop("integer", "セルの列"), "row": prop("integer", "セルの行"),
                "name": prop("string", "名前"), "passable": prop("boolean", "通行できるか"), "z": prop("integer", "重なり順（0 が通常、大きいほど手前）"),
            ], required: ["col", "row"]) { a in
                var n = e.meta.annotation(col: try a.int("col"), row: try a.int("row"))
                if let v = a.optString("name") { n.name = v }
                if let v = a.optBool("passable") { n.passable = v }
                if let v = a.optInt("z") { n.z = v }
                e.meta.setAnnotation(n)
                return .text("セル (\(n.col), \(n.row)) を更新しました")
            },

            // MARK: アニメ

            MCPTool("list_anims", "アニメの一覧（コマの座標を含む）") { _ in
                .json(e.meta.anims.map { an -> [String: Any] in
                    ["name": an.name, "mode": an.mode.rawValue, "frame_width": an.frameWidth, "frame_height": an.frameHeight,
                     "frames": an.resolvedFrames.map { ["x": $0.x, "y": $0.y, "duration": $0.duration] }]
                })
            },

            MCPTool("set_anim", """
            アニメを作る・変える（name で探し、なければ作る）。
            grid: origin_x/origin_y から columns × rows に並んだ count コマを interval ミリ秒ずつ。
            list: frames [{x, y, duration}] の順に再生
            """, properties: [
                "name": prop("string", "名前"),
                "mode": ["type": "string", "enum": ["grid", "list"], "description": "grid（簡易）か list（登録）"],
                "frame_width": prop("integer", "コマの幅"), "frame_height": prop("integer", "コマの高さ"),
                "origin_x": prop("integer", "grid の起点 x"), "origin_y": prop("integer", "grid の起点 y"),
                "columns": prop("integer", "grid の列数"), "rows": prop("integer", "grid の行数"),
                "count": prop("integer", "grid の枚数"), "interval": prop("integer", "grid の間隔（ミリ秒）"),
                "frames": ["type": "array", "items": ["type": "object"], "description": "list のコマ [{x, y, duration}]"],
                "delete": prop("boolean", "true ならこのアニメを消す"),
            ], required: ["name"]) { a in
                let name = try a.string("name")
                if a.optBool("delete") == true {
                    e.meta.anims.removeAll { $0.name == name }
                    return .text("\(name) を消しました")
                }
                var an = e.meta.anims.first { $0.name == name }
                    ?? AnimDef(name: name, frameWidth: e.meta.cellWidth, frameHeight: e.meta.cellHeight)
                if let m = a.optString("mode") { an.mode = AnimDef.Mode(rawValue: m) ?? an.mode }
                if let v = a.optInt("frame_width") { an.frameWidth = max(1, v) }
                if let v = a.optInt("frame_height") { an.frameHeight = max(1, v) }
                if let v = a.optInt("origin_x") { an.originX = v }
                if let v = a.optInt("origin_y") { an.originY = v }
                if let v = a.optInt("columns") { an.columns = max(1, v) }
                if let v = a.optInt("rows") { an.rows = max(1, v) }
                if let v = a.optInt("count") { an.count = max(1, v) }
                if let v = a.optInt("interval") { an.interval = max(10, v) }
                if let list = a.array("frames") as? [[String: Any]] {
                    an.frames = try list.map { f in
                        let p = MCPArgs(f)
                        return AnimFrame(x: try p.int("x"), y: try p.int("y"), duration: max(10, p.optInt("duration") ?? 150))
                    }
                    if !a.has("mode") { an.mode = .list }
                }
                if let i = e.meta.anims.firstIndex(where: { $0.name == name }) { e.meta.anims[i] = an } else { e.meta.anims.append(an) }
                return .text("\(name): \(an.resolvedFrames.count) コマ")
            },

            // MARK: マップ

            MCPTool("list_maps", "マップの一覧（名前・大きさ・レイヤー名）") { _ in
                .json(e.meta.maps.enumerated().map { i, m -> [String: Any] in
                    ["index": i, "name": m.name, "width": m.width, "height": m.height, "layers": m.layers.map(\.name)]
                })
            },

            MCPTool("get_map", "マップのタイルを返す。各レイヤーの rows は行ごとのセル番号（-1 は空）", properties: [
                "map": prop("string", "マップの名前か番号（省略時は最初のマップ）"),
            ]) { a in
                let m = e.meta.maps[try findMap(a, e)]
                return .json([
                    "name": m.name, "width": m.width, "height": m.height,
                    "sheet_columns": max(1, e.image.width / max(1, e.meta.cellWidth)),
                    "layers": m.layers.map { l -> [String: Any] in
                        ["name": l.name, "visible": l.visible,
                         "rows": (0..<m.height).map { y in Array(l.tiles[(y * m.width)..<((y + 1) * m.width)]) }]
                    },
                ])
            },

            MCPTool("create_map", "マップを作る", properties: [
                "name": prop("string", "名前"), "width": prop("integer", "横のタイル数"), "height": prop("integer", "縦のタイル数"),
                "layers": prop("integer", "レイヤー数（省略時 2）"),
            ], required: ["name", "width", "height"]) { a in
                let m = TileMapDef(name: try a.string("name"), width: try a.int("width"), height: try a.int("height"),
                                   layerCount: a.optInt("layers") ?? 2)
                e.meta.maps.append(m)
                return .text("マップ \(m.name)（\(m.width)×\(m.height)、レイヤー \(m.layers.count)）を作りました。番号は \(e.meta.maps.count - 1)")
            },

            MCPTool("set_map_tiles", "マップの (x, y) を左上に、tiles（行ごとのセル番号の 2 次元配列。-1 で消す、null で変えない）を置く", properties: [
                "map": prop("string", "マップの名前か番号（省略時は最初のマップ）"),
                "layer": prop("integer", "レイヤー番号（0 が一番下、省略時 0）"),
                "x": prop("integer", "左上 x（タイル単位）"), "y": prop("integer", "左上 y（タイル単位）"),
                "tiles": ["type": "array", "items": ["type": "array"], "description": "[[セル番号]]"],
                "resize_width": prop("integer", "先にマップの横幅を変える"), "resize_height": prop("integer", "先にマップの縦幅を変える"),
            ], required: ["x", "y", "tiles"]) { a in
                let i = try findMap(a, e)
                var m = e.meta.maps[i]
                if a.has("resize_width") || a.has("resize_height") {
                    m.resize(width: a.optInt("resize_width") ?? m.width, height: a.optInt("resize_height") ?? m.height)
                }
                let layer = a.optInt("layer") ?? 0
                guard m.layers.indices.contains(layer) else { throw MCPError("レイヤー \(layer) はありません（0〜\(m.layers.count - 1)）") }
                guard let rows = a.array("tiles") as? [[Any]] else { throw MCPError("tiles は 2 次元配列です") }
                let ox = try a.int("x"), oy = try a.int("y")
                var n = 0
                for (dy, row) in rows.enumerated() {
                    for (dx, v) in row.enumerated() {
                        guard let t = (v as? NSNumber)?.intValue else { continue }
                        m.set(layer, ox + dx, oy + dy, t)
                        n += 1
                    }
                }
                e.meta.maps[i] = m
                return .text("\(m.name) のレイヤー \(layer) に \(n) タイル置きました")
            },

            // MARK: ファイル

            MCPTool("new_sheet", "新しい空のシートにする（保存していない変更は失われる）", properties: [
                "width": prop("integer", "幅"), "height": prop("integer", "高さ"),
                "cell_width": prop("integer", "セルの幅（省略時 32）"), "cell_height": prop("integer", "セルの高さ（省略時 32）"),
            ], required: ["width", "height"]) { a in
                let w = try a.int("width"), h = try a.int("height")
                guard (1...8192).contains(w), (1...8192).contains(h) else { throw MCPError("大きさは 1〜8192 です") }
                e.newDocument(width: w, height: h, cellWidth: a.optInt("cell_width") ?? 32, cellHeight: a.optInt("cell_height") ?? 32)
                host.sheetReplaced()
                return .json(sheetInfo(e))
            },

            MCPTool("open_sheet", "PNG などの画像を開く（同じ名前の .nanodot.json があれば設定も読む。保存していない変更は失われる）", properties: [
                "path": prop("string", "ファイルの絶対パス"),
            ], required: ["path"]) { a in
                let url = URL(fileURLWithPath: (try a.string("path") as NSString).expandingTildeInPath)
                let (img, meta) = try SheetFile.load(url: url)
                e.load(img, meta: meta ?? SheetMeta(), url: url.pathExtension.lowercased() == "png" ? url : nil)
                host.sheetReplaced()
                return .json(sheetInfo(e))
            },

            MCPTool("save_sheet", "PNG と <名前>.nanodot.json に保存する。path を省くと今のファイルに上書き", properties: [
                "path": prop("string", "保存先の .png の絶対パス（省略時は今のファイル）"),
            ]) { a in
                let url: URL
                if let p = a.optString("path") {
                    url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                } else if let u = e.fileURL {
                    url = u
                } else {
                    throw MCPError("まだ保存先がありません。path を指定してください")
                }
                guard url.pathExtension.lowercased() == "png" else { throw MCPError("保存先は .png にしてください") }
                try SheetFile.save(e.image, meta: e.meta, url: url)
                e.markSaved(url: url)
                return .text("\(url.path) に保存しました")
            },
        ]
    }
}
