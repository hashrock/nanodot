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
        let url = try tempDir().appendingPathComponent("sheet.png")
        try SheetFile.save(img, meta: meta, url: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("sheet.nanodot.json").path))
        let (loaded, m) = try SheetFile.load(url: url)
        XCTAssertEqual(loaded, img)
        XCTAssertEqual(m?.cellWidth, 24)
        XCTAssertEqual(m?.slots[3], RGBA(9, 8, 7))
        XCTAssertEqual(m?.anims.first?.frames.first?.x, 1)
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
