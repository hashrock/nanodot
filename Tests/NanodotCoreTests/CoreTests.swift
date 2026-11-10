import Foundation
import ImageIO
@testable import NanodotCore
import XCTest

final class PixelTests: XCTestCase {
    func testHexRoundTrip() {
        let c = RGBA(0x12, 0xab, 0xcd, 0x80)
        XCTAssertEqual(RGBA(hex: c.hex), c)
        XCTAssertEqual(RGBA(hex: "#ff0000"), RGBA(255, 0, 0))
        XCTAssertNil(RGBA(hex: "xyz"))
    }

    func testTransparentIsNormalized() {
        var b = PixelBuffer(width: 2, height: 1)
        b[0, 0] = RGBA(10, 20, 30, 0)
        XCTAssertEqual(b[0, 0], .clear)
    }

    func testRotateAndFlip() {
        // 2x1: [A B]
        let a = RGBA(255, 0, 0), b = RGBA(0, 255, 0)
        let buf = PixelBuffer(width: 2, height: 1, pixels: [a, b])
        let cw = buf.rotatedClockwise()
        XCTAssertEqual(cw.width, 1)
        XCTAssertEqual(cw.pixels, [a, b])
        let ccw = buf.rotatedCounterClockwise()
        XCTAssertEqual(ccw.pixels, [b, a])
        XCTAssertEqual(buf.flippedHorizontally().pixels, [b, a])
        XCTAssertEqual(buf.rotatedClockwise().rotatedCounterClockwise(), buf)
    }

    func testShiftWraps() {
        let a = RGBA(1, 1, 1), b = RGBA(2, 2, 2), c = RGBA(3, 3, 3)
        let buf = PixelBuffer(width: 3, height: 1, pixels: [a, b, c])
        XCTAssertEqual(buf.shifted(1, 0).pixels, [c, a, b])
        XCTAssertEqual(buf.shifted(-1, 0).pixels, [b, c, a])
    }

    func testPasteSkipsTransparent() {
        var dst = PixelBuffer(width: 2, height: 1, fill: .white)
        let src = PixelBuffer(width: 2, height: 1, pixels: [.black, .clear])
        dst.paste(src, at: .zero, skipTransparent: true)
        XCTAssertEqual(dst.pixels, [.black, .white])
        dst.paste(src, at: .zero, skipTransparent: false)
        XCTAssertEqual(dst.pixels, [.black, .clear])
    }

    func testCopyOutOfBoundsIsTransparent() {
        let buf = PixelBuffer(width: 2, height: 2, fill: .white)
        let c = buf.copy(IntRect(x: 1, y: 1, width: 2, height: 2))
        XCTAssertEqual(c.pixels, [.white, .clear, .clear, .clear])
    }
}

final class RasterTests: XCTestCase {
    func testLineEndpoints() {
        let pts = Raster.line(IntPoint(0, 0), IntPoint(5, 2))
        XCTAssertEqual(pts.first, IntPoint(0, 0))
        XCTAssertEqual(pts.last, IntPoint(5, 2))
        XCTAssertEqual(pts.count, 6)
    }

    func testRectOutline() {
        XCTAssertEqual(Raster.rect(IntPoint(0, 0), IntPoint(2, 2), filled: false).count, 8)
        XCTAssertEqual(Raster.rect(IntPoint(2, 2), IntPoint(0, 0), filled: true).count, 9)
    }

    func testEllipseSymmetric() {
        let pts = Set(Raster.ellipse(IntPoint(0, 0), IntPoint(9, 6), filled: false))
        for p in pts {
            XCTAssertTrue(pts.contains(IntPoint(9 - p.x, p.y)))
            XCTAssertTrue(pts.contains(IntPoint(p.x, 6 - p.y)))
        }
        let filled = Raster.ellipse(IntPoint(0, 0), IntPoint(9, 6), filled: true)
        XCTAssertGreaterThan(filled.count, pts.count)
    }

    func testConstrain() {
        XCTAssertEqual(Raster.constrain(IntPoint(0, 0), IntPoint(5, 1), diagonalSnap: true), IntPoint(5, 0))
        XCTAssertEqual(Raster.constrain(IntPoint(0, 0), IntPoint(5, 4), diagonalSnap: true), IntPoint(5, 5))
        XCTAssertEqual(Raster.constrain(IntPoint(0, 0), IntPoint(-3, 1), diagonalSnap: false), IntPoint(-3, 3))
    }

    func testFloodClip() {
        let buf = PixelBuffer(width: 10, height: 10)
        let r = Raster.floodRegion(buf, from: IntPoint(1, 1), clip: IntRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertEqual(r.count, 16)
    }
}

final class EditorTests: XCTestCase {
    func makeEditor() -> Editor {
        let e = Editor(width: 64, height: 64)
        e.meta.lupeWidth = 16
        e.meta.lupeHeight = 16
        return e
    }

    func testPlotIsClippedToMark() {
        let e = makeEditor()
        e.beginEdit()
        e.plot([IntPoint(0, 0), IntPoint(20, 20)], color: .black)
        e.endEdit("ペン")
        XCTAssertEqual(e.image[0, 0], .black)
        XCTAssertEqual(e.image[20, 20], .clear)
    }

    func testUndoRedo() {
        let e = makeEditor()
        e.beginEdit()
        e.plot([IntPoint(1, 1)], color: .black)
        e.endEdit("ペン")
        XCTAssertTrue(e.canUndo)
        XCTAssertTrue(e.isDirty)
        e.undo()
        XCTAssertEqual(e.image[1, 1], .clear)
        e.redo()
        XCTAssertEqual(e.image[1, 1], .black)
    }

    func testEmptyEditIsNotRecorded() {
        let e = makeEditor()
        e.beginEdit()
        e.plot([IntPoint(100, 100)], color: .black)
        e.endEdit("ペン")
        XCTAssertFalse(e.canUndo)
    }

    func testMarkMoveIsNotDirty() {
        let e = makeEditor()
        e.setMark(IntPoint(8, 8))
        e.setLupe(width: 8, height: 8)
        XCTAssertFalse(e.isDirty)
        e.meta.cellWidth = 16
        XCTAssertTrue(e.isDirty)
    }

    func testMarkClamp() {
        let e = makeEditor()
        e.setMark(IntPoint(100, -5))
        XCTAssertEqual(e.meta.mark, IntPoint(48, 0))
    }

    func testSwapRegion() {
        let e = makeEditor()
        e.beginEdit()
        e.plot([IntPoint(0, 0)], color: .black)
        e.endEdit("ペン")
        e.swapMarkRegion(to: IntPoint(16, 0))
        XCTAssertEqual(e.image[0, 0], .clear)
        XCTAssertEqual(e.image[16, 0], .black)
        XCTAssertEqual(e.meta.mark, IntPoint(16, 0))
        e.undo()
        XCTAssertEqual(e.image[0, 0], .black)
        XCTAssertEqual(e.meta.mark, IntPoint(0, 0))
    }

    func testStampSkipsTransparent() {
        let e = makeEditor()
        e.setClipboard(PixelBuffer(width: 2, height: 1, pixels: [.black, .clear]))
        e.apply(.fill) // 黒で塗ってから白で塗り直す
        e.color = .white
        e.apply(.fill)
        e.stamp(at: IntPoint(0, 0), overwrite: false, clipToWork: true)
        XCTAssertEqual(e.image[0, 0], .black)
        XCTAssertEqual(e.image[1, 0], .white)
        e.stamp(at: IntPoint(0, 0), overwrite: true, clipToWork: true)
        XCTAssertEqual(e.image[1, 0], .clear)
    }

    func testFloodFillAndReplace() {
        let e = makeEditor()
        e.color = RGBA(255, 0, 0)
        e.floodFill(at: IntPoint(3, 3), color: e.color)
        XCTAssertEqual(e.image[15, 15], RGBA(255, 0, 0))
        XCTAssertEqual(e.image[16, 16], .clear)
        e.replaceColor(RGBA(255, 0, 0), with: .black, inMarkOnly: false)
        XCTAssertEqual(e.image[15, 15], .black)
        let stats = e.colorStats()
        XCTAssertEqual(stats.first { $0.color == .black }?.count, 256)
    }

    func testRegionOps() {
        let e = makeEditor()
        e.beginEdit()
        e.plot([IntPoint(0, 0)], color: .black)
        e.endEdit("ペン")
        e.apply(.flipH)
        XCTAssertEqual(e.image[15, 0], .black)
        e.apply(.rotateCW)
        XCTAssertEqual(e.image[15, 15], .black)
        e.apply(.shift(1, 1))
        XCTAssertEqual(e.image[0, 0], .black)
    }

    func testZoomLupe() {
        let e = makeEditor() // 64x64、ルーペ 16x16、スナップはセル(32)の 1/2 = 16
        e.setMark(IntPoint(16, 16))
        e.zoomLupe(zoomIn: false, anchor: IntPoint(24, 24))
        XCTAssertEqual(e.meta.lupeWidth, 32)
        XCTAssertEqual(e.meta.mark, IntPoint(16, 16))
        e.zoomLupe(zoomIn: false, anchor: IntPoint(24, 24))
        XCTAssertEqual(e.meta.lupeWidth, 64)
        XCTAssertEqual(e.meta.mark, .zero)
        e.zoomLupe(zoomIn: false, anchor: IntPoint(24, 24))
        XCTAssertEqual(e.meta.lupeWidth, 64, "シート全体より大きくはしない")
        e.zoomLupe(zoomIn: true, anchor: IntPoint(40, 40))
        XCTAssertEqual(e.meta.lupeWidth, 32)
        XCTAssertEqual(e.meta.mark, IntPoint(16, 16))
        XCTAssertFalse(e.isDirty)
    }

    func testResizeUndo() {
        let e = makeEditor()
        e.resizeSheet(width: 32, height: 16)
        XCTAssertEqual(e.image.width, 32)
        e.undo()
        XCTAssertEqual(e.image.width, 64)
    }
}

final class AnimTests: XCTestCase {
    func testGridFrames() {
        var a = AnimDef(name: "歩き", frameWidth: 24, frameHeight: 32)
        a.originX = 48
        a.columns = 3
        a.rows = 2
        a.count = 5
        let f = a.resolvedFrames
        XCTAssertEqual(f.count, 5)
        XCTAssertEqual(f[1].x, 72)
        XCTAssertEqual(f[3].x, 48)
        XCTAssertEqual(f[3].y, 32)
    }

    func testSnap() {
        var m = SheetMeta()
        m.snap = .pixels(8)
        XCTAssertEqual(m.snapped(IntPoint(15, -1)), IntPoint(8, -8))
        m.snap = .cell(1)
        m.cellWidth = 24
        XCTAssertEqual(m.snapped(IntPoint(50, 40)), IntPoint(48, 32))
        XCTAssertEqual(m.snappedDelta(IntPoint(13, -17)), IntPoint(24, -32))
        m.snap = .cell(2)
        XCTAssertEqual(m.snapped(IntPoint(50, 40)), IntPoint(48, 32))
        XCTAssertEqual(m.snapped(IntPoint(37, 17)), IntPoint(36, 16))
        m.snap = .cell(4)
        XCTAssertEqual(m.snapX, 6)
        XCTAssertEqual(m.snapY, 8)
    }

    func testSnapCoding() throws {
        for s in Snap.choices {
            let data = try JSONEncoder().encode([s])
            XCTAssertEqual(try JSONDecoder().decode([Snap].self, from: data), [s])
        }
        XCTAssertEqual(SheetMeta().snap, .cell(2))
    }
}

final class FileTests: XCTestCase {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nanodot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testSaveLoadRoundTrip() throws {
        var img = PixelBuffer(width: 4, height: 3)
        img[0, 0] = RGBA(1, 2, 3, 255)
        img[1, 0] = RGBA(200, 100, 50, 128)
        var meta = SheetMeta()
        meta.cellWidth = 24
        meta.slots[3] = RGBA(9, 8, 7)
        var a = AnimDef(name: "a", frameWidth: 2, frameHeight: 2)
        a.mode = .list
        a.frames = [AnimFrame(x: 1, y: 2, duration: 100)]
        meta.anims = [a]
        meta.maps = [TileMapDef(name: "村の広場", width: 2, height: 1)]
        let dir = try tempDir(), url = dir.appendingPathComponent("sheet.png")
        try SheetFile.save(img, meta: meta, url: url)
        // 書くのは PNG と、名前が同じで拡張子が 1 段だけ違うサイドカー
        XCTAssertEqual(SheetFile.sidecarURL(for: url).lastPathComponent, "sheet.nanodot")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["sheet.nanodot", "sheet.png"])
        let (loaded, m) = try SheetFile.load(url: url)
        XCTAssertEqual(loaded, img)
        XCTAssertEqual(m?.cellWidth, 24)
        XCTAssertEqual(m?.slots[3], RGBA(9, 8, 7))
        XCTAssertEqual(m?.anims.first?.frames.first?.x, 1)
        XCTAssertEqual(m?.maps.first?.name, "村の広場")
        // PNG は素のまま（ほかのアプリからも同じ画像）で、サイドカーの中身は JSON
        XCTAssertEqual(SheetFile.pixelBuffer(pngData: try Data(contentsOf: url)), img)
        XCTAssertEqual(SheetFile.decodeMeta(try Data(contentsOf: SheetFile.sidecarURL(for: url)))?.cellWidth, 24)
        // 上書き
        img[2, 2] = RGBA(7, 7, 7, 255)
        meta.cellWidth = 12
        try SheetFile.save(img, meta: meta, url: url)
        let again = try SheetFile.load(url: url)
        XCTAssertEqual(again.image, img)
        XCTAssertEqual(again.meta?.cellWidth, 12)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["sheet.nanodot", "sheet.png"])
    }

    /// サイドカーがない・壊れている PNG は素の画像として開く
    func testPlainPNGAndBrokenSidecar() throws {
        var img = PixelBuffer(width: 3, height: 2)
        img[1, 1] = RGBA(10, 20, 30, 200)
        let dir = try tempDir(), url = dir.appendingPathComponent("p.png")
        try XCTUnwrap(SheetFile.pngData(img)).write(to: url)
        let plain = try SheetFile.load(url: url)
        XCTAssertEqual(plain.image, img)
        XCTAssertNil(plain.meta)
        try Data("こわれた".utf8).write(to: SheetFile.sidecarURL(for: url))
        let broken = try SheetFile.load(url: url)
        XCTAssertEqual(broken.image, img)
        XCTAssertNil(broken.meta)
        XCTAssertThrowsError(try SheetFile.load(url: dir.appendingPathComponent("none.png")))
    }

    /// 古い名前（<名前>.nanodot.json）は読めるまま。新しい名前があればそちらを優先し、保存は新しい名前だけに書く
    func testLegacySidecar() throws {
        var img = PixelBuffer(width: 4, height: 4)
        img[1, 1] = RGBA(10, 20, 30, 255)
        var old = SheetMeta()
        old.cellWidth = 2
        old.maps = [TileMapDef(name: "a", width: 1, height: 1)]
        let dir = try tempDir(), png = dir.appendingPathComponent("old.png"), legacy = dir.appendingPathComponent("old.nanodot.json")
        XCTAssertEqual(SheetFile.legacySidecarURL(for: png), legacy)
        try XCTUnwrap(SheetFile.pngData(img)).write(to: png)
        // 古い版が書いていたキー（engineExport / exportedFiles）があっても読める
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: SheetFile.encodeMeta(old)) as? [String: Any])
        json["engineExport"] = true
        json["exportedFiles"] = ["old.a.tmj"]
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        try legacyData.write(to: legacy)
        // 古い版が隣に書いたゲームエンジン用データ
        try Data("tmj".utf8).write(to: dir.appendingPathComponent("old.a.tmj"))

        let (loaded, m) = try SheetFile.load(url: png)
        XCTAssertEqual(loaded, img)
        XCTAssertEqual(m?.cellWidth, 2)
        XCTAssertEqual(m?.maps.first?.name, "a")

        // 保存は新しい名前だけに書く。古いサイドカーも、古い版が書いたゲームエンジン用データも消さず、書き換えない
        var new = try XCTUnwrap(m)
        new.cellWidth = 3
        new.maps = []
        try SheetFile.save(loaded, meta: new, url: png)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["old.a.tmj", "old.nanodot", "old.nanodot.json", "old.png"])
        XCTAssertEqual(try Data(contentsOf: legacy), legacyData)
        // 両方あれば新しい名前を優先
        XCTAssertEqual(try SheetFile.load(url: png).meta?.cellWidth, 3)
        // 新しいほうがなくなれば、残っている古い名前を読む
        try FileManager.default.removeItem(at: SheetFile.sidecarURL(for: png))
        XCTAssertEqual(try SheetFile.load(url: png).meta?.cellWidth, 2)
    }

    /// 関連ファイルの読み書き（コーディネーター経由）
    func testRelatedFile() throws {
        let dir = try tempDir(), png = dir.appendingPathComponent("r.png"), side = dir.appendingPathComponent("r.nanodot")
        XCTAssertNil(RelatedFile.read(side, primary: png))
        try RelatedFile.write(Data("a".utf8), to: side, primary: png)
        XCTAssertEqual(RelatedFile.read(side, primary: png), Data("a".utf8))
        try RelatedFile.write(Data("bb".utf8), to: side, primary: png)
        XCTAssertEqual(try Data(contentsOf: side), Data("bb".utf8))
        // 書けない場所ならエラー
        let missing = dir.appendingPathComponent("no/such/r.png")
        XCTAssertThrowsError(try RelatedFile.write(Data("c".utf8), to: SheetFile.sidecarURL(for: missing), primary: missing))
    }

    func testAnimExport() throws {
        var img = PixelBuffer(width: 8, height: 4)
        img.fill(IntRect(x: 4, y: 0, width: 4, height: 4), with: .black)
        var a = AnimDef(name: "a", frameWidth: 4, frameHeight: 4)
        a.columns = 2
        a.count = 2
        let frames = AnimExport.frames(of: a, in: img, scale: 2)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].0.width, 8)
        let d = try tempDir()
        for (name, write) in [("a.gif", AnimExport.writeGIF), ("a.png", AnimExport.writeAPNG)] {
            let url = d.appendingPathComponent(name)
            try write(frames, url)
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(src), 2, name)
        }
        let seq = try AnimExport.writePNGSequence(frames, directory: d, baseName: "walk")
        XCTAssertEqual(seq.map(\.lastPathComponent), ["walk_000.png", "walk_001.png"])
    }
}

final class SlotOpsTests: XCTestCase {
    func testGradientRGB() {
        var s = [RGBA?](repeating: nil, count: 8)
        s[1] = RGBA(0, 0, 0)
        s[5] = RGBA(200, 100, 40)
        let g = SlotOps.gradient(s, 5, 1, hsl: false)
        XCTAssertEqual(g[3], RGBA(100, 50, 20))
        XCTAssertEqual(g[1], s[1])
        XCTAssertEqual(g[5], s[5])
        XCTAssertNil(g[6])
        // 端が空なら変えない
        XCTAssertEqual(SlotOps.gradient(s, 1, 6, hsl: false), s)
    }

    func testGradientHSLShortHue() {
        // 赤(0°)→マゼンタ(300°) は 330° 付近を通る（緑側を回らない）
        let mid = SlotOps.lerpHSL(RGBA(255, 0, 0), RGBA(255, 0, 255), 0.5)
        XCTAssertEqual(mid.g, 0)
        XCTAssertGreaterThan(mid.r, mid.b)
    }

    func testHSLRoundTrip() {
        for c in [RGBA(12, 200, 99), RGBA(255, 255, 255), RGBA(0, 0, 0), RGBA(128, 64, 200)] {
            XCTAssertEqual(HSL(c).rgba(alpha: 255), c)
        }
    }

    func testMoveAndReverse() {
        let a = RGBA(1, 1, 1), b = RGBA(2, 2, 2)
        let s: [RGBA?] = [a, nil, b]
        XCTAssertEqual(SlotOps.move(s, from: 0, to: 1, copy: false), [nil, a, b])
        XCTAssertEqual(SlotOps.move(s, from: 0, to: 2, copy: true), [a, nil, a])
        XCTAssertEqual(SlotOps.reversed(s, 0, 2), [b, nil, a])
    }
}

final class MapTests: XCTestCase {
    func testStampFillResize() {
        var m = TileMapDef(name: "m", width: 4, height: 3)
        m.stamp(0, 1, 1, MapBrush(width: 2, height: 1, tiles: [5, -1]))
        XCTAssertEqual(m.tile(0, 1, 1), 5)
        XCTAssertEqual(m.tile(0, 2, 1), -1)
        m.stamp(0, 3, 2, MapBrush(width: 2, height: 2, tiles: [7, 7, 7, 7])) // はみ出しは無視
        XCTAssertEqual(m.tile(0, 3, 2), 7)
        m.fill(1, 0, 0, 3)
        XCTAssertEqual(m.layers[1].tiles, Array(repeating: 3, count: 12))
        m.fill(0, 0, 0, 9)
        XCTAssertEqual(m.tile(0, 1, 1), 5, "違うタイルで区切られた所は塗らない")
        XCTAssertEqual(m.tile(0, 2, 2), 9)
        XCTAssertEqual(m.brush(0, IntRect(x: 1, y: 1, width: 2, height: 1)).tiles, [5, 9])
        m.resize(width: 2, height: 2)
        XCTAssertEqual(m.layers[0].tiles, [9, 9, 9, 5])
    }

    func testAnnotationsAndCoding() throws {
        var meta = SheetMeta()
        var a = meta.annotation(col: 2, row: 1)
        a.passable = false
        a.z = 1
        a.name = "壁"
        meta.setAnnotation(a)
        var m = TileMapDef(name: "村", width: 3, height: 2)
        m.set(1, 2, 1, SheetMeta.cellIndex(col: 2, row: 1, columns: 8))
        meta.maps = [m]
        let decoded = try JSONDecoder().decode(SheetMeta.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(decoded.annotation(col: 2, row: 1).name, "壁")
        XCTAssertFalse(decoded.annotation(col: 2, row: 1).passable)
        XCTAssertEqual(decoded.maps.first?.tile(1, 2, 1), 10)
        XCTAssertEqual(decoded.maps.first?.layers.count, 2)
        // 既定値に戻すと消える
        a.passable = true; a.z = 0; a.name = ""
        meta.setAnnotation(a)
        XCTAssertTrue(meta.annotations.isEmpty)
        XCTAssertTrue(SheetMeta.cellPosition(10, columns: 8) == (2, 1))
    }
}

final class TextTests: XCTestCase {
    func testRenderIsCrispAndColored() throws {
        var s = TextSettings()
        s.size = 16
        let b = try XCTUnwrap(TextRenderer.render("Ab\nあ", settings: s, color: RGBA(255, 0, 0)))
        XCTAssertGreaterThan(b.width, 8)
        XCTAssertGreaterThan(b.height, 16, "2 行ぶんの高さ")
        // アンチエイリアスなしなら色は 1 色だけ
        XCTAssertEqual(Set(b.pixels.filter { $0.a > 0 }), [RGBA(255, 0, 0)])
        // 切り詰めているので上端と左端に画素がある
        XCTAssertTrue((0..<b.width).contains { b[$0, 0].a > 0 })
        XCTAssertTrue((0..<b.height).contains { b[0, $0].a > 0 })
    }

    func testDrawTextUndo() {
        let e = Editor(width: 64, height: 32)
        e.setLupe(width: 64, height: 32)
        e.drawText("Hi", at: IntPoint(2, 2), settings: TextSettings(), color: .black)
        XCTAssertTrue(e.image.pixels.contains(.black))
        e.undo()
        XCTAssertFalse(e.image.pixels.contains(.black))
    }
}

#if !APPSTORE
final class MCPTests: XCTestCase {
    final class Host: MCPHost {
        let editor = Editor(width: 64, height: 32)
        var replaced = 0
        func sheetReplaced() { replaced += 1 }
    }

    func call(_ s: MCPServer, _ method: String, _ params: [String: Any] = [:], id: Int = 1) throws -> [String: Any] {
        let req: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let out = try XCTUnwrap(s.handle(try JSONSerialization.data(withJSONObject: req)))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    func tool(_ s: MCPServer, _ name: String, _ args: [String: Any] = [:]) throws -> (text: String, isError: Bool, content: [[String: Any]]) {
        let r = try XCTUnwrap(try call(s, "tools/call", ["name": name, "arguments": args])["result"] as? [String: Any])
        let content = r["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, r["isError"] as? Bool ?? false, content)
    }

    func testInitializeAndList() throws {
        let s = NanodotMCP.server(host: Host(), version: "test")
        let r = try XCTUnwrap(try call(s, "initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "t"]])["result"] as? [String: Any])
        XCTAssertEqual(r["protocolVersion"] as? String, "2025-03-26")
        let tools = try XCTUnwrap((try call(s, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "draw_text" })
        // 通知には返さない
        let note = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(s.handle(note))
        XCTAssertEqual((try call(s, "nope")["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testPixelsRoundTripAndUndo() throws {
        let host = Host()
        let s = NanodotMCP.server(host: host, version: "test")
        // マーク範囲（既定 32×32）の外にも描ける
        let set = try tool(s, "set_pixels", ["x": 40, "y": 1, "palette": ["#ff0000", "transparent"], "rows": ["0 1 0", ". 0 ."]])
        XCTAssertFalse(set.isError, set.text)
        XCTAssertEqual(host.editor.image[40, 1], RGBA(255, 0, 0))
        XCTAssertEqual(host.editor.image[41, 2], RGBA(255, 0, 0))
        let got = try tool(s, "get_pixels", ["x": 40, "y": 1, "width": 3, "height": 2])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(got.text.utf8)) as? [String: Any])
        XCTAssertEqual(json["rows"] as? [String], ["0 1 0", "1 0 1"])
        XCTAssertFalse(try tool(s, "undo").isError)
        XCTAssertEqual(host.editor.image[40, 1], .clear)
    }

    func testShapesTextImageAndErrors() throws {
        let host = Host()
        let s = NanodotMCP.server(host: host, version: "test")
        XCTAssertFalse(try tool(s, "draw_shape", ["shape": "rect", "x1": 0, "y1": 0, "x2": 63, "y2": 31, "color": "#000000"]).isError)
        XCTAssertEqual(host.editor.image[63, 31], .black)
        XCTAssertFalse(try tool(s, "fill", ["x": 10, "y": 10, "color": "#00ff00"]).isError)
        XCTAssertEqual(host.editor.image[50, 20], RGBA(0, 255, 0))
        XCTAssertFalse(try tool(s, "draw_text", ["x": 2, "y": 2, "text": "A", "color": "#ffffff", "size": 10]).isError)
        XCTAssertTrue(host.editor.image.pixels.contains(.white))
        let img = try tool(s, "get_image")
        XCTAssertEqual(img.content.first?["type"] as? String, "image")
        XCTAssertTrue(try tool(s, "draw_shape", ["shape": "star", "x1": 0, "y1": 0, "x2": 1, "y2": 1, "color": "#000000"]).isError)
        XCTAssertTrue(try tool(s, "fill_rect", ["x": 0, "y": 0, "width": 2, "height": 2, "color": "red"]).isError)
    }

    /// set_palette は、名前を変えたパレットの古い名前（0.4.0 までの「ゲームボーイ」）も受け付ける
    func testSetPaletteAcceptsOldName() throws {
        let host = Host()
        let s = NanodotMCP.server(host: host, version: "test")
        XCTAssertFalse(try tool(s, "set_palette", ["palette": "ゲームボーイ"]).isError)
        XCTAssertEqual(host.editor.meta.palette, "緑の濃淡")
        XCTAssertFalse(try tool(s, "set_palette", ["palette": "PICO-8"]).isError)
        XCTAssertFalse(try tool(s, "set_palette", ["palette": "緑の濃淡"]).isError)
        XCTAssertEqual(host.editor.meta.palette, "緑の濃淡")
        XCTAssertTrue(try tool(s, "set_palette", ["palette": "ないパレット"]).isError)
    }

    func testMetaTools() throws {
        let host = Host()
        let s = NanodotMCP.server(host: host, version: "test")
        XCTAssertFalse(try tool(s, "set_annotation", ["col": 1, "row": 0, "passable": false]).isError)
        XCTAssertFalse(host.editor.meta.annotation(col: 1, row: 0).passable)
        XCTAssertFalse(try tool(s, "set_anim", ["name": "walk", "columns": 2, "count": 2]).isError)
        XCTAssertEqual(host.editor.meta.anims.first?.resolvedFrames.count, 2)
        XCTAssertFalse(try tool(s, "create_map", ["name": "村", "width": 4, "height": 3]).isError)
        XCTAssertFalse(try tool(s, "set_map_tiles", ["map": "村", "layer": 1, "x": 1, "y": 1, "tiles": [[0, 1], [NSNull(), -1]]]).isError)
        XCTAssertEqual(host.editor.meta.maps[0].tile(1, 2, 1), 1)
        XCTAssertFalse(try tool(s, "new_sheet", ["width": 16, "height": 16]).isError)
        XCTAssertEqual(host.replaced, 1)
        XCTAssertEqual(host.editor.image.width, 16)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nanodot-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        func names(_ d: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: d.path).sorted() }
        let path = dir.appendingPathComponent("a.png").path
        XCTAssertTrue(try tool(s, "export_engine_data").isError)
        XCTAssertFalse(try tool(s, "set_annotation", ["col": 0, "row": 0, "name": "草"]).isError)
        XCTAssertFalse(try tool(s, "create_map", ["name": "m", "width": 1, "height": 1]).isError)
        XCTAssertFalse(try tool(s, "save_sheet", ["path": path]).isError)
        // 保存は PNG とサイドカーだけ。ゲームエンジン用データは書かない
        XCTAssertEqual(try names(dir), ["a.nanodot", "a.png"])
        XCTAssertFalse(try tool(s, "new_sheet", ["width": 8, "height": 8]).isError)
        XCTAssertFalse(try tool(s, "open_sheet", ["path": path]).isError)
        XCTAssertEqual(host.editor.fileURL?.path, path)
        XCTAssertEqual(host.editor.meta.maps.first?.name, "m")
        XCTAssertEqual(host.editor.meta.annotation(col: 0, row: 0).name, "草")
        // 書き出しは明示的に
        XCTAssertFalse(try tool(s, "export_engine_data").isError)
        XCTAssertEqual(try names(dir), ["a.atlas.json", "a.m.tmj", "a.nanodot", "a.png"])
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertFalse(try tool(s, "export_engine_data", ["folder": out.path]).isError)
        XCTAssertEqual(try names(out), ["a.atlas.json", "a.m.tmj"])
    }
}
#endif

final class EngineExportTests: XCTestCase {
    private func object(_ d: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    func testNothingToWrite() {
        XCTAssertTrue(EngineExport.files(imageName: "a.png", width: 64, height: 64, meta: SheetMeta()).isEmpty)
    }

    func testAtlasHasAnimFramesTagsAndNamedCells() throws {
        var m = SheetMeta()
        m.cellWidth = 16; m.cellHeight = 16
        var walk = AnimDef(name: "walk", frameWidth: 16, frameHeight: 16)
        walk.columns = 2; walk.count = 2; walk.interval = 120
        m.anims = [walk]
        var c = CellAnnotation(col: 1, row: 2)
        c.name = "coin"
        m.setAnnotation(c)
        let files = EngineExport.files(imageName: "hero.png", width: 64, height: 64, meta: m)
        XCTAssertEqual(files.map(\.name), ["hero.atlas.json"])
        let o = try object(files[0].data)
        let frames = try XCTUnwrap(o["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.map { $0["filename"] as? String }, ["walk 0", "walk 1", "coin"])
        XCTAssertEqual(frames[1]["frame"] as? [String: Int], ["x": 16, "y": 0, "w": 16, "h": 16])
        XCTAssertEqual(frames[1]["duration"] as? Int, 120)
        XCTAssertEqual(frames[2]["frame"] as? [String: Int], ["x": 16, "y": 32, "w": 16, "h": 16])
        let meta = try XCTUnwrap(o["meta"] as? [String: Any])
        XCTAssertEqual(meta["image"] as? String, "hero.png")
        let tags = try XCTUnwrap(meta["frameTags"] as? [[String: Any]])
        XCTAssertEqual(tags.first?["from"] as? Int, 0)
        XCTAssertEqual(tags.first?["to"] as? Int, 1)
    }

    func testTiledMapGidsAndProperties() throws {
        var m = SheetMeta()
        m.cellWidth = 16; m.cellHeight = 16
        var map = TileMapDef(name: "field 1", width: 3, height: 1, layerCount: 1)
        map.set(0, 0, 0, 5)
        map.set(0, 2, 0, 99) // シートの外は空にする
        m.maps = [map, TileMapDef(name: "field 1", width: 1, height: 1)]
        var wall = CellAnnotation(col: 1, row: 1)
        wall.passable = false
        m.setAnnotation(wall)
        let files = EngineExport.files(imageName: "tiles.png", width: 64, height: 32, meta: m)
        XCTAssertEqual(files.map(\.name), ["tiles.field_1.tmj", "tiles.field_1-2.tmj"])
        let o = try object(files[0].data)
        XCTAssertEqual(o["tilewidth"] as? Int, 16)
        let layer = try XCTUnwrap((o["layers"] as? [[String: Any]])?.first)
        XCTAssertEqual(layer["data"] as? [Int], [6, 0, 0])
        let ts = try XCTUnwrap((o["tilesets"] as? [[String: Any]])?.first)
        XCTAssertEqual(ts["columns"] as? Int, 4)
        XCTAssertEqual(ts["tilecount"] as? Int, 8)
        let tile = try XCTUnwrap((ts["tiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(tile["id"] as? Int, 5)
        let props = try XCTUnwrap(tile["properties"] as? [[String: Any]])
        XCTAssertEqual(props.first?["value"] as? Bool, false)
    }

    func testAtlasDedupesNamesAndSkipsFramesOutsideSheet() throws {
        var m = SheetMeta()
        m.cellWidth = 16; m.cellHeight = 16
        var a = AnimDef(name: "walk", frameWidth: 16, frameHeight: 16)
        a.columns = 3; a.count = 3 // 3 コマ目は幅 32 のシートからはみ出す
        m.anims = [a, AnimDef(name: "walk", frameWidth: 16, frameHeight: 16)]
        m.anims[1].columns = 1; m.anims[1].count = 1
        var dup = CellAnnotation(col: 0, row: 0)
        dup.name = "walk 0"
        m.setAnnotation(dup)
        var outside = CellAnnotation(col: 5, row: 0)
        outside.name = "far"
        m.setAnnotation(outside)
        let o = try object(EngineExport.files(imageName: "a.png", width: 32, height: 16, meta: m)[0].data)
        let frames = try XCTUnwrap(o["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.map { $0["filename"] as? String }, ["walk 0", "walk 1", "walk-2 0", "walk 0-2"])
        let tags = try XCTUnwrap((o["meta"] as? [String: Any])?["frameTags"] as? [[String: Any]])
        XCTAssertEqual(tags.map { $0["name"] as? String }, ["walk", "walk-2"])
        XCTAssertEqual(tags.map { $0["to"] as? Int }, [1, 2])
    }

    func testFileSafe() {
        XCTAssertEqual(EngineExport.fileSafe(""), "map")
        XCTAssertEqual(EngineExport.fileSafe("../a/b"), ".._a_b")
        XCTAssertEqual(EngineExport.fileSafe("a\nb:c"), "a_b_c")
    }

    // MARK: - 保存（SheetFile 経由）

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nanodot-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func mapMeta(_ names: [String]) -> SheetMeta {
        var m = SheetMeta()
        m.cellWidth = 16; m.cellHeight = 16
        m.maps = names.map { TileMapDef(name: $0, width: 1, height: 1) }
        return m
    }

    private func names(_ d: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: d.path).sorted()
    }

    func testSaveDoesNotExport() throws {
        let d = try tempDir(), url = d.appendingPathComponent("t.png")
        try SheetFile.save(PixelBuffer(width: 32, height: 32), meta: mapMeta(["a"]), url: url)
        XCTAssertEqual(try names(d), ["t.nanodot", "t.png"])
    }

    func testWriteToFolderAndSkipsUnchanged() throws {
        let d = try tempDir()
        var meta = mapMeta(["a", "b"])
        var note = CellAnnotation(col: 0, row: 0)
        note.name = "草"
        meta.annotations = [note]
        XCTAssertEqual(try EngineExport.write(imageName: "t.png", width: 32, height: 32, meta: meta, to: d), ["t.atlas.json", "t.a.tmj", "t.b.tmj"])
        XCTAssertEqual(try names(d), ["t.a.tmj", "t.atlas.json", "t.b.tmj"])
        let map = try object(Data(contentsOf: d.appendingPathComponent("t.a.tmj")))
        XCTAssertEqual((map["tilesets"] as? [[String: Any]])?.first?["image"] as? String, "t.png")
        // 中身が同じなら書き直さない。変わったものだけ書く
        let past = Date(timeIntervalSince1970: 1_000_000)
        for n in try names(d) { try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: d.appendingPathComponent(n).path) }
        meta.maps[1].set(0, 0, 0, 1)
        try EngineExport.write(imageName: "t.png", width: 32, height: 32, meta: meta, to: d)
        func mod(_ n: String) throws -> Date? { try FileManager.default.attributesOfItem(atPath: d.appendingPathComponent(n).path)[.modificationDate] as? Date }
        XCTAssertEqual(try mod("t.a.tmj"), past)
        XCTAssertEqual(try mod("t.atlas.json"), past)
        XCTAssertNotEqual(try mod("t.b.tmj"), past)
        // 書くものがなければ何も作らない
        let empty = try tempDir()
        XCTAssertEqual(try EngineExport.write(imageName: "t.png", width: 32, height: 32, meta: SheetMeta(), to: empty), [])
        XCTAssertEqual(try names(empty), [])
    }

    func testWriteFailureThrows() throws {
        let d = try tempDir()
        // 書き出し先と同名のフォルダーがあると書けない
        try FileManager.default.createDirectory(at: d.appendingPathComponent("t.a.tmj"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try EngineExport.write(imageName: "t.png", width: 32, height: 32, meta: mapMeta(["a"]), to: d))
    }

    func testExportFolderBookmark() throws {
        let d = try tempDir()
        let b = try ExportFolder.bookmark(for: d)
        XCTAssertEqual(ExportFolder.resolve(b)?.standardizedFileURL.path, d.standardizedFileURL.path)
        XCTAssertNil(ExportFolder.resolve(Data([1, 2, 3])))
    }
}

final class SettingsMigrationTests: XCTestCase {
    // 実際の UserDefaults には触らない（空の設定ファイルが残るため）。写す値を決めるところだけを試す
    func testCopiesOldSettings() throws {
        let old: [String: Any] = ["dragThreshold": 3, "onionSkin": false, "exportFolders": ["/a.png": Data([1, 2])]]
        let add = try XCTUnwrap(SettingsMigration.additions(current: [:], legacy: [old]))
        XCTAssertEqual(add.count, 3)
        XCTAssertEqual(add["dragThreshold"] as? Int, 3)
        XCTAssertEqual(add["onionSkin"] as? Bool, false)
        XCTAssertEqual((add["exportFolders"] as? [String: Any])?["/a.png"] as? Data, Data([1, 2]))
    }

    func testKeepsNewValues() throws {
        let add = try XCTUnwrap(SettingsMigration.additions(current: ["dragThreshold": 5], legacy: [["dragThreshold": 3, "onionSkin": false]]))
        XCTAssertEqual(add.keys.sorted(), ["onionSkin"])
    }

    func testOnlyOnce() {
        // 済んだ印があれば何も写さない（新しい側で変えた・消した値を、古い値で戻さない）
        XCTAssertNil(SettingsMigration.additions(current: [SettingsMigration.doneKey: ["x"]], legacy: [["dragThreshold": 3]]))
        // 古い設定がなくても、写すものが空で返る（呼び出し側が印を付ける）
        XCTAssertEqual(SettingsMigration.additions(current: [:], legacy: [])?.count, 0)
    }

    func testFirstLegacyDomainWins() throws {
        let add = try XCTUnwrap(SettingsMigration.additions(current: [:], legacy: [["a": 1], ["a": 2, "b": 3]]))
        XCTAssertEqual(add["a"] as? Int, 1)
        XCTAssertEqual(add["b"] as? Int, 3)
    }
}
