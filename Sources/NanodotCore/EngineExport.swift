import Foundation

/// ゲームエンジン向けのデータ（保存時に PNG の隣へ書く）
/// - `<名前>.atlas.json`: アニメと名前付きセルのフレーム（Aseprite / TexturePacker の JSON Array 形式）
/// - `<名前>.<マップ名>.tmj`: マップ（Tiled の JSON 形式。注釈はタイルのプロパティ）
public enum EngineExport {
    /// 書き出すファイル（ファイル名と中身）。書くものがなければ空
    public static func files(imageName: String, width: Int, height: Int, meta: SheetMeta) -> [(name: String, data: Data)] {
        let baseName = (imageName as NSString).deletingPathExtension
        var out: [(String, Data)] = []
        if let a = atlas(imageName: imageName, width: width, height: height, meta: meta) {
            out.append(("\(baseName).atlas.json", json(a)))
        }
        guard !meta.maps.isEmpty else { return out }
        let ts = tileset(name: baseName, imageName: imageName, width: width, height: height, meta: meta)
        var used = Set<String>()
        for m in meta.maps {
            let base = fileSafe(m.name)
            var name = base, n = 2
            while used.contains(name) {
                name = "\(base)-\(n)"
                n += 1
            }
            used.insert(name)
            out.append(("\(baseName).\(name).tmj", json(tiledMap(m, tileset: ts, meta: meta))))
        }
        return out
    }

    /// アニメのコマ（"アニメ名 番号"）と名前付きセル。frameTags にアニメごとの範囲を持つ
    static func atlas(imageName: String, width: Int, height: Int, meta: SheetMeta) -> [String: Any]? {
        var frames: [[String: Any]] = []
        var tags: [[String: Any]] = []
        for anim in meta.anims {
            let fs = anim.resolvedFrames
            guard !fs.isEmpty else { continue }
            tags.append(["name": anim.name, "from": frames.count, "to": frames.count + fs.count - 1, "direction": "forward"])
            for (i, f) in fs.enumerated() {
                frames.append(frame("\(anim.name) \(i)", anim.rect(of: f), duration: f.duration))
            }
        }
        for a in meta.annotations where !a.name.isEmpty {
            frames.append(frame(a.name, meta.cellRect(col: a.col, row: a.row), duration: 100))
        }
        guard !frames.isEmpty else { return nil }
        return [
            "frames": frames,
            "meta": [
                "app": "https://hashrock.github.io/nanodot/",
                "image": imageName,
                "format": "RGBA8888",
                "size": ["w": width, "h": height],
                "scale": "1",
                "frameTags": tags,
            ] as [String: Any],
        ]
    }

    private static func frame(_ name: String, _ r: IntRect, duration: Int) -> [String: Any] {
        [
            "filename": name,
            "frame": ["x": r.x, "y": r.y, "w": r.width, "h": r.height],
            "rotated": false,
            "trimmed": false,
            "spriteSourceSize": ["x": 0, "y": 0, "w": r.width, "h": r.height],
            "sourceSize": ["w": r.width, "h": r.height],
            "duration": duration,
        ]
    }

    /// シート 1 枚のタイルセット。注釈はタイルのプロパティにする
    static func tileset(name: String, imageName: String, width: Int, height: Int, meta: SheetMeta) -> [String: Any] {
        let cols = meta.columns(imageWidth: width), rows = meta.rows(imageHeight: height)
        let tiles: [[String: Any]] = meta.annotations.filter { $0.col < cols && $0.row < rows }.map { a in
            var props: [[String: Any]] = [
                ["name": "passable", "type": "bool", "value": a.passable],
                ["name": "z", "type": "int", "value": a.z],
            ]
            if !a.name.isEmpty { props.append(["name": "name", "type": "string", "value": a.name]) }
            return ["id": SheetMeta.cellIndex(col: a.col, row: a.row, columns: cols), "properties": props]
        }
        return [
            "firstgid": 1, "name": name, "image": imageName, "imagewidth": width, "imageheight": height,
            "tilewidth": meta.cellWidth, "tileheight": meta.cellHeight, "columns": cols, "tilecount": cols * rows,
            "margin": 0, "spacing": 0, "tiles": tiles,
        ]
    }

    /// Tiled の JSON マップ。gid はセル番号 + 1（空とシート外は 0）
    static func tiledMap(_ m: TileMapDef, tileset: [String: Any], meta: SheetMeta) -> [String: Any] {
        let count = tileset["tilecount"] as? Int ?? 0
        let layers: [[String: Any]] = m.layers.enumerated().map { i, l in
            [
                "type": "tilelayer", "id": i + 1, "name": l.name, "visible": l.visible, "opacity": 1,
                "x": 0, "y": 0, "width": m.width, "height": m.height,
                "data": l.tiles.map { $0 >= 0 && $0 < count ? $0 + 1 : 0 },
            ]
        }
        return [
            "type": "map", "version": "1.10", "orientation": "orthogonal", "renderorder": "right-down", "infinite": false,
            "width": m.width, "height": m.height, "tilewidth": meta.cellWidth, "tileheight": meta.cellHeight,
            "nextlayerid": layers.count + 1, "nextobjectid": 1,
            "layers": layers, "tilesets": [tileset],
        ]
    }

    private static let unsafeChars = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.whitespacesAndNewlines).union(.controlCharacters)

    /// ファイル名に使えない文字を _ に置き換える
    static func fileSafe(_ s: String) -> String {
        let t = String(s.unicodeScalars.map { unsafeChars.contains($0) ? "_" : Character($0) })
        return t.isEmpty ? "map" : t
    }

    private static func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
