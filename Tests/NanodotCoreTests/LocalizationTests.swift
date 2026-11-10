import XCTest
@testable import NanodotCore

/// 訳のカタログ（Resources/*.xcstrings）と、訳の引き方
final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("nanodot-l10n-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        Localization.bundle = .main
        try? FileManager.default.removeItem(at: work)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// カタログをアプリに入れるときと同じ手順で表にし、英語の表から引くようにする
    private func useEnglish() throws {
        for table in ["Localizable", "MCP"] {
            let r = try run("/usr/bin/xcrun", ["xcstringstool", "compile", Self.root.appendingPathComponent("Resources/\(table).xcstrings").path,
                                               "--output-directory", work.path])
            XCTAssertEqual(r.status, 0, r.output)
        }
        Localization.bundle = try XCTUnwrap(Bundle(url: work.appendingPathComponent("en.lproj")))
    }

    /// 訳の抜け・包み忘れ・使っていないキーがない（scripts/check-localization.py）
    func testCatalogMatchesSources() throws {
        let r = try run("/usr/bin/python3", [Self.root.appendingPathComponent("scripts/check-localization.py").path, "--quiet"])
        XCTAssertEqual(r.status, 0, r.output)
    }

    func testJapaneseIsTheSourceLanguage() {
        // バンドルがない（訳の表がない）ときは、キーの日本語がそのまま出る
        XCTAssertEqual(Tool.pen.displayName, "ペン (B)")
        XCTAssertEqual(Snap.pixels(4).label, "4 ドット")
        XCTAssertEqual(Snap.cell(2).label, "セルの 1/2")
        XCTAssertEqual(LName("緑の濃淡"), "緑の濃淡")
        XCTAssertEqual(TileMapDef(name: "村", width: 2, height: 2).layers.map(\.name), ["レイヤー 1", "レイヤー 2"])
    }

    func testEnglish() throws {
        try useEnglish()
        XCTAssertEqual(Tool.pen.displayName, "Pen (B)")
        XCTAssertEqual(Tool.allCases.map(\.displayName).filter { $0.unicodeScalars.contains { $0.value > 0x2fff } }, [], "ツールの名前に日本語が残っていない")
        XCTAssertEqual(Snap.choices.map(\.label), ["Cell", "1/2 Cell", "1/4 Cell", "1 px", "2 px", "4 px", "8 px", "16 px", "32 px"])
        XCTAssertEqual(AnimExport.Format.allCases.map(\.label), ["Animated GIF", "APNG", "PNG Sequence"])
        XCTAssertEqual(SheetFileError.unreadable.localizedDescription, "The image could not be read.")
        XCTAssertEqual(TextRenderer.fonts.first?.name, "system")
        // 補間: 整数は %lld、文字列は %@ のキーになる
        XCTAssertEqual(L("レイヤー \(3)"), "Layer 3")
        XCTAssertEqual(L("取り消し: \(L("ペン"))"), "Undo Pen")
        XCTAssertEqual(L("\("a").atlas.json と \("a").<マップ名>.tmj を書き出すフォルダーを選択（\("a.png") と同じ場所に置くと、そのまま読めます）"),
                       "Choose a folder for a.atlas.json and a.<map name>.tmj. (Put them next to a.png and they can be loaded as is.)")
        #if !APPSTORE
        XCTAssertEqual(LM("起動できません: \("x")"), "Could not start: x")
        #endif

        // 取り消しの名前
        let e = Editor()
        e.newDocument(width: 8, height: 8, cellWidth: 8, cellHeight: 8)
        e.apply(.fill)
        XCTAssertEqual(e.undoLabel, "Fill")
    }

    /// 0.4.0 までのパレット名「ゲームボーイ」は「緑の濃淡」として読める
    func testRenamedPaletteIsStillReadable() throws {
        XCTAssertFalse(SamplePalette.all.contains { $0.name == "ゲームボーイ" })
        XCTAssertEqual(SamplePalette.named("ゲームボーイ").name, "緑の濃淡")
        XCTAssertEqual(SamplePalette.named("ゲームボーイ").colors.map(\.hex), SamplePalette.named("緑の濃淡").colors.map(\.hex))
        XCTAssertEqual(SamplePalette.named("緑の濃淡").colors.count, 4)

        // 古いサイドカー: 読むと今の名前になり、保存し直すと今の名前で書かれる
        var meta = SheetMeta()
        meta.palette = "緑の濃淡"
        let old = String(decoding: try SheetFile.encodeMeta(meta), as: UTF8.self).replacingOccurrences(of: "緑の濃淡", with: "ゲームボーイ")
        XCTAssertTrue(old.contains("ゲームボーイ"))
        let decoded = try XCTUnwrap(SheetFile.decodeMeta(Data(old.utf8)))
        XCTAssertEqual(decoded.palette, "緑の濃淡")
        XCTAssertFalse(String(decoding: try SheetFile.encodeMeta(decoded), as: UTF8.self).contains("ゲームボーイ"))
    }

    /// 保存する値は、どちらの言語で作っても同じ。訳は表示のときだけ当てる
    func testSavedDataDoesNotDependOnLanguage() throws {
        let japanese = try SheetFile.encodeMeta(SheetMeta())
        try useEnglish()
        XCTAssertEqual(try SheetFile.encodeMeta(SheetMeta()), japanese)

        // 同梱パレットは日本語の名前のまま保存し、表示のときに訳す
        XCTAssertTrue(SamplePalette.all.contains { $0.name == "緑の濃淡" })
        XCTAssertEqual(LName("緑の濃淡"), "Green Shades")
        XCTAssertEqual(LName("PICO-8"), "PICO-8")
        XCTAssertEqual(LName("村の広場"), "村の広場", "ユーザーが付けた名前はそのまま")
        var meta = SheetMeta()
        meta.palette = "緑の濃淡"
        let decoded = try XCTUnwrap(SheetFile.decodeMeta(try SheetFile.encodeMeta(meta)))
        XCTAssertEqual(decoded.palette, "緑の濃淡")
        XCTAssertEqual(SamplePalette.named(decoded.palette).colors.count, 4)

        // 名前のないマップ・レイヤーのない古いデータは、どちらの言語で読んでも同じ値になる
        let old = try JSONDecoder().decode(TileMapDef.self, from: Data(#"{"width":2,"height":1}"#.utf8))
        XCTAssertEqual(old.name, "マップ")
        XCTAssertEqual(old.layers.map(\.name), ["レイヤー 1"])

        // 新しく作るものの名前は、作ったときの言語で決まり、そのまま保存される（ユーザーが付けた名前と同じ扱い）
        let map = TileMapDef(name: L("マップ \(1)"), width: 2, height: 2)
        XCTAssertEqual(map.name, "Map 1")
        XCTAssertEqual(map.layers.map(\.name), ["Layer 1", "Layer 2"])
        Localization.bundle = .main
        let reread = try JSONDecoder().decode(TileMapDef.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(reread.layers.map(\.name), ["Layer 1", "Layer 2"], "日本語の環境で開いても変わらない")
    }
}
