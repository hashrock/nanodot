import CoreGraphics
import NanodotCore

/// マップの仮組みの表示（Mac 版の MapCanvasView と iPad 版の MapPadView で共有）。
/// 画面は左上原点（Mac は isFlipped）。origin はマップの左上の画面座標、zoom は 1 ドットの画面上の大きさ
struct MapViewport {
    var origin: CGPoint
    var zoom: CGFloat
    var cellWidth: Int
    var cellHeight: Int

    var tileSize: CGSize { CGSize(width: CGFloat(cellWidth) * zoom, height: CGFloat(cellHeight) * zoom) }

    func tileRect(_ x: Int, _ y: Int, w: Int = 1, h: Int = 1) -> CGRect {
        let t = tileSize
        return CGRect(x: origin.x + CGFloat(x) * t.width, y: origin.y + CGFloat(y) * t.height, width: t.width * CGFloat(w), height: t.height * CGFloat(h))
    }

    func tile(at p: CGPoint) -> IntPoint {
        let t = tileSize
        return IntPoint(Int(floor((p.x - origin.x) / t.width)), Int(floor((p.y - origin.y) / t.height)))
    }

    /// p を動かさずに倍率を変える（origin は整数にそろえる）
    mutating func setZoom(_ nz: CGFloat, around p: CGPoint) {
        let ix = (p.x - origin.x) / zoom, iy = (p.y - origin.y) / zoom
        zoom = nz
        origin = CGPoint(x: (p.x - ix * nz).rounded(), y: (p.y - iy * nz).rounded())
    }
}

enum MapDraw {
    /// 拡大縮小の段階
    static let zoomLevels: [CGFloat] = [0.25, 0.5, 1, 2, 3, 4, 6, 8]

    static func steppedZoom(_ zoom: CGFloat, by d: Int) -> CGFloat {
        let i = zoomLevels.firstIndex { $0 >= zoom } ?? zoomLevels.count - 1
        return zoomLevels[min(max(0, i + d), zoomLevels.count - 1)]
    }

    /// マップのタイル・注釈の ×・格子・外枠を描く（背景は呼ぶ側で塗る）
    static func map(_ ctx: CGContext, bounds: CGRect, viewport v: MapViewport, session: MapSession, sheet: CGImage?, showAnnotations: Bool) {
        guard let map = session.map else { return }
        ctx.interpolationQuality = .none
        let area = v.tileRect(0, 0, w: map.width, h: map.height)
        Draw.fillChecker(ctx, area.intersection(bounds), origin: area.origin, dot: v.zoom)

        // 見えている範囲のタイルだけ描く
        let t = v.tileSize
        let x0 = max(0, Int(floor((bounds.minX - v.origin.x) / t.width))), y0 = max(0, Int(floor((bounds.minY - v.origin.y) / t.height)))
        let x1 = min(map.width - 1, Int(ceil((bounds.maxX - v.origin.x) / t.width))), y1 = min(map.height - 1, Int(ceil((bounds.maxY - v.origin.y) / t.height)))
        if x0 <= x1, y0 <= y1 {
            for (li, layer) in map.layers.enumerated() where layer.visible {
                for y in y0...y1 {
                    for x in x0...x1 {
                        let idx = layer.tiles[y * map.width + x]
                        guard idx >= 0, let img = session.cellImage(idx, sheet: sheet) else { continue }
                        // 選択中より上のレイヤーは薄く
                        Draw.image(ctx, img, in: CGRect(origin: v.tileRect(x, y).origin,
                                                        size: CGSize(width: CGFloat(img.width) * v.zoom, height: CGFloat(img.height) * v.zoom)),
                                   alpha: li > session.layer ? 0.45 : 1)
                    }
                }
            }

            // 通れないタイル（表示中のどれかのレイヤーで通行不可）に ×
            if showAnnotations {
                let blocked = session.editor.meta.blockedCells(columns: session.sheetColumns)
                if !blocked.isEmpty {
                    ctx.saveGState()
                    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.25, alpha: 0.9))
                    ctx.setLineWidth(2)
                    for y in y0...y1 {
                        for x in x0...x1 where map.layers.contains(where: { $0.visible && blocked.contains($0.tiles[y * map.width + x]) }) {
                            let r = v.tileRect(x, y).insetBy(dx: t.width * 0.3, dy: t.height * 0.3)
                            ctx.move(to: CGPoint(x: r.minX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                            ctx.move(to: CGPoint(x: r.maxX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                        }
                    }
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
        }

        Draw.grid(ctx, area: area.intersection(bounds), origin: area.origin, stepX: t.width, stepY: t.height,
                  color: CGColor(gray: 0.5, alpha: 0.25))
        Draw.outline(ctx, area.insetBy(dx: -1, dy: -1), color: CGColor(gray: 0.4, alpha: 0.8))
    }

    /// ブラシの影（p はブラシの左上のタイル）。ペン・塗りつぶしはタイルを薄く重ね、消しゴムは枠だけ
    static func brushGhost(_ ctx: CGContext, viewport v: MapViewport, session: MapSession, sheet: CGImage?, at p: IntPoint) {
        let b = session.tool == .fill ? MapBrush.single(session.brush.tiles.first ?? -1) : session.brush
        if session.tool != .eraser {
            for by in 0..<b.height {
                for bx in 0..<b.width {
                    guard let img = session.cellImage(b.tiles[by * b.width + bx], sheet: sheet) else { continue }
                    Draw.image(ctx, img, in: CGRect(origin: v.tileRect(p.x + bx, p.y + by).origin,
                                                    size: CGSize(width: CGFloat(img.width) * v.zoom, height: CGFloat(img.height) * v.zoom)), alpha: 0.6)
                }
            }
        }
        Draw.outline(ctx, v.tileRect(p.x, p.y, w: b.width, h: b.height))
    }
}
