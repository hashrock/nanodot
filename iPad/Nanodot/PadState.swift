import NanodotCore
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iPad 版のアプリの状態（書類・表示の共有状態・ファイル操作）
@Observable
final class PadState {
    let editor = Editor()

    /// 開いているファイル名（拡張子なし。タイトル表示と保存の名前）
    var documentName = L("無題")
    /// アプリのフォルダー（書類フォルダー・iCloud container）の外にある書類を開いている。
    /// このときはサイドカー（<名前>.nanodot）を読まず・書かず、素の画像として扱う
    private(set) var isOutsideDocument = false
    /// iCloud container の書類フォルダー（ファイル App の「iCloud Drive › Nanodot」）。iCloud を使えなければ nil
    private(set) var iCloudDocuments: URL?

    /// 画面の下に少しの間だけ出す知らせ
    var toast: String?
    @ObservationIgnored private var toastToken: UUID?

    // MARK: アニメ
    var selectedAnimID: UUID?
    /// アニメのパネルを出しているか（オニオンスキンの表示条件。Mac 版の「アニメウィンドウが開いている」にあたる）
    var animPanelVisible = false
    var onionSkin: Bool = UserDefaults.standard.object(forKey: "onionSkin") as? Bool ?? true {
        didSet { UserDefaults.standard.set(onionSkin, forKey: "onionSkin") }
    }
    /// アニメのプレビューで表示中のコマ（ストックに枠を出す）
    @ObservationIgnored var previewFrameRect: IntRect?

    // MARK: 入力の設定
    /// 指でも描く（オフなら指は表示の操作だけ。描くのは Apple Pencil）
    var fingerDrawing: Bool = UserDefaults.standard.bool(forKey: "pad.fingerDrawing") {
        didSet {
            UserDefaults.standard.set(fingerDrawing, forKey: "pad.fingerDrawing")
            mainView?.updateGestureConfiguration()
        }
    }
    /// スタンプで透明部分を抜く（Mac 版の ⌥ にあたる）
    var stampSkipTransparent = false
    /// 長押しのあと、範囲コピーとみなすまでの移動ドット数（Mac 版の「右ドラッグの判定」）
    var dragThreshold: Int = UserDefaults.standard.object(forKey: "dragThreshold") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(dragThreshold, forKey: "dragThreshold") }
    }

    /// Apple Pencil のダブルタップ（設定が「カラーパレットを表示」のとき）で色のパネルを出す（増えたら出す）
    var showColorsRequest = 0
    /// ストックの表示倍率（表示用。実体は StockPadView）
    var stockZoom: CGFloat = 1

    @ObservationIgnored weak var mainView: MainPadView?
    @ObservationIgnored weak var stockView: StockPadView?
    @ObservationIgnored weak var previewView: AnimPreviewPadView?

    /// 点滅の表示相（パレットで色を選んだとき、その色の場所を少しの間点滅させる）
    @ObservationIgnored private(set) var blinkOn = false
    @ObservationIgnored private var blinkTimer: Timer?
    @ObservationIgnored private var imageCache: (version: Int, image: CGImage)?
    @ObservationIgnored private var pasteboardChangeCount = -1

    /// 外の場所（ファイル App で選んだ場所）のファイルを開いている間のアクセス権
    @ObservationIgnored private var accessedURL: URL?

    init() {
        editor.newDocument(width: 256, height: 256, cellWidth: 32, cellHeight: 32)
        editor.onPixelsChanged = { [weak self] in self?.requestDisplay() }
        locateICloudContainer()
        if !restoreLastDocument() { prepareFirstLaunch() }
        #if targetEnvironment(simulator)
        // 検証用（シミュレーターだけ）。引数は SimulatorHooks.swift
        DispatchQueue.main.async { [self] in
            if let path = UserDefaults.standard.string(forKey: "open") { open(url: URL(fileURLWithPath: path)) }
            SimulatorHooks.run(self)
        }
        #endif
    }

    // MARK: - 表示

    /// シート画像（画素が変わったときだけ作り直す）
    var sheetImage: CGImage? {
        if let c = imageCache, c.version == editor.pixelVersion { return c.image }
        guard let img = SheetFile.cgImage(from: editor.image) else { return nil }
        imageCache = (editor.pixelVersion, img)
        return img
    }

    func requestDisplay() {
        mainView?.setNeedsDisplay()
        stockView?.setNeedsDisplay()
        previewView?.setNeedsDisplay()
    }

    func show(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.toastToken == token else { return }
            withAnimation { self.toast = nil }
        }
    }

    /// その色を使っている場所を少しの間点滅させる（Mac 版は押している間。iPad はタップなので時間で止める）
    func flashHighlight(_ c: RGBA) {
        editor.highlight = c
        blinkTimer?.invalidate()
        blinkOn = true
        var ticks = 0
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            ticks += 1
            self.blinkOn.toggle()
            if ticks >= 6 {
                t.invalidate()
                self.blinkOn = false
                self.editor.highlight = nil
            }
            self.mainView?.setNeedsDisplay()
            self.stockView?.setNeedsDisplay()
        }
        requestDisplay()
    }

    // MARK: - マーク

    func moveMark(dx: Int, dy: Int, byLupe: Bool) {
        let m = editor.meta
        if byLupe {
            editor.setMark(IntPoint(m.mark.x + dx * m.lupeWidth, m.mark.y + dy * m.lupeHeight))
        } else {
            editor.moveMark(dx: dx, dy: dy)
        }
        stockView?.scrollMarkToVisible()
        requestDisplay()
    }

    // MARK: - クリップボード

    /// 内部のクリップボードに置き、システムのクリップボードにも PNG で書く
    func setClipboard(_ b: PixelBuffer) {
        editor.setClipboard(b)
        guard let data = SheetFile.pngData(b) else { return }
        UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
        pasteboardChangeCount = UIPasteboard.general.changeCount
    }

    func copyMark() {
        if let b = editor.copy(editor.markRect) {
            setClipboard(b)
            show(L("マーク範囲をコピーしました"))
        }
    }

    /// ほかのアプリで画像がコピーされていればそれを取り込んで、スタンプモードへ
    func pasteToStamp() {
        let pb = UIPasteboard.general
        if pb.changeCount != pasteboardChangeCount {
            if let data = pb.data(forPasteboardType: UTType.png.identifier), let b = SheetFile.pixelBuffer(pngData: data) {
                editor.setClipboard(b)
            } else if let img = pb.image?.cgImage, let b = SheetFile.pixelBuffer(from: img) {
                editor.setClipboard(b)
            }
            pasteboardChangeCount = pb.changeCount
        }
        if editor.clipboard != nil {
            editor.stampActive = true
        } else {
            show(L("貼り付ける画像がありません"))
        }
        requestDisplay()
    }

    // MARK: - フォルダー

    /// アプリの書類フォルダー（ファイル App の「このiPad内 › Nanodot」）
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// iCloud container を探す（時間がかかることがあるので裏で）。書類フォルダーを作っておくと、ファイル App の iCloud Drive に出る
    private func locateICloudContainer() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return }
            let docs = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                guard let self else { return }
                self.iCloudDocuments = docs
                // 探している間に開いた書類が iCloud container の中だったら、扱いを直す
                if self.isOutsideDocument, let u = self.editor.fileURL, self.appFolders.contains(u), !self.editor.isDirty {
                    self.open(url: u)
                }
            }
        }
    }

    /// サイドカーを読み書きできる場所: アプリの書類フォルダーと iCloud container
    var appFolders: AppFolders {
        AppFolders(roots: [Self.documentsDirectory] + (iCloudDocuments.map { [$0] } ?? []))
    }

    /// 書類フォルダーが空だと、ファイル App に「このiPad内 › Nanodot」が出ない。
    /// 初めて起動したときは、最初の白紙のシートを「無題.png」として置いておく（そのまま上書き保存の先になる）
    private func prepareFirstLaunch() {
        let fm = FileManager.default
        let d = UserDefaults.standard
        guard !d.bool(forKey: "pad.didFirstLaunch") else { return }
        d.set(true, forKey: "pad.didFirstLaunch")
        let contents = (try? fm.contentsOfDirectory(atPath: Self.documentsDirectory.path)) ?? []
        guard contents.filter({ !$0.hasPrefix(".") }).isEmpty else { return }
        save(quiet: true)
    }

    // MARK: - 書類

    static let openableTypes: [UTType] = [.png, .gif, .bmp, .tiff, .jpeg]

    func newDocument(width: Int, height: Int, cellWidth: Int, cellHeight: Int) {
        releaseAccess()
        isOutsideDocument = false
        editor.newDocument(width: width, height: height, cellWidth: cellWidth, cellHeight: cellHeight)
        documentName = L("無題")
        sheetReplaced()
        rememberLastDocument()
    }

    private func sheetReplaced() {
        selectedAnimID = editor.meta.anims.first?.id
        stockView?.fitToView()
        requestDisplay()
    }

    /// ファイル App などから渡されたファイルを開く
    func open(url: URL) {
        // サイドカー（<名前>.nanodot）を渡されたら、隣の PNG を開く
        let url = url.pathExtension.lowercased() == SheetFile.sidecarExtension ? url.deletingPathExtension().appendingPathExtension("png") : url
        releaseAccess()
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            // iCloud Drive やほかのアプリのフォルダーの書類もあるので、調停（NSFileCoordinator）を通して読む
            let data = try CoordinatedFile.read(url)
            guard let img = SheetFile.pixelBuffer(pngData: data) else { throw SheetFileError.unreadable }
            let isPNG = url.pathExtension.lowercased() == "png"
            // サイドカーはアプリのフォルダーの中でだけ読む。外の書類は素の画像として開く
            let inside = appFolders.contains(url)
            let meta = inside ? RelatedFile.read(SheetFile.sidecarURL(for: url), primary: url).flatMap(SheetFile.decodeMeta) : nil
            var m = meta ?? SheetMeta()
            if meta == nil { m.slots = editor.meta.slots }
            // PNG 以外は上書き保存しない（保存すると アプリのフォルダーに PNG を作る）
            editor.load(img, meta: m, url: isPNG ? url : nil)
            isOutsideDocument = isPNG && !inside
            // 上書き保存できるよう、閉じるまでアクセス権を持っておく
            if scoped {
                if isPNG { accessedURL = url } else { url.stopAccessingSecurityScopedResource() }
            }
            documentName = url.deletingPathExtension().lastPathComponent
            sheetReplaced()
            rememberLastDocument()
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            show(L("ファイルを開けませんでした: \(error.localizedDescription)"))
        }
    }

    /// ドロップされたファイルを受け取る。元の場所のまま開ければそのまま（scoped = true で受け取り側がアクセス権を手放す）、
    /// 開けなければコピーを渡す
    func receiveDropped(_ providers: [NSItemProvider], completion: @escaping (URL, Bool) -> Void) -> Bool {
        for provider in providers {
            guard let type = Self.openableTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { continue }
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: type.identifier) { [self] url, inPlace, _ in
                guard let url else {
                    DispatchQueue.main.async { self.show(L("ファイルを受け取れませんでした")) }
                    return
                }
                if inPlace && url.startAccessingSecurityScopedResource() {
                    DispatchQueue.main.async { completion(url, true) }
                    return
                }
                do {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let copy = dir.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: copy)
                    DispatchQueue.main.async { completion(copy, false) }
                } catch {
                    DispatchQueue.main.async { self.show(L("ファイルを受け取れませんでした: \(error.localizedDescription)")) }
                }
            }
            return true
        }
        return false
    }

    private func releaseAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    /// 上書き保存。まだファイルがなければアプリの書類フォルダーに新しく作る
    @discardableResult
    func save(quiet: Bool = false) -> Bool {
        do {
            let url = editor.fileURL ?? uniqueURL(name: documentName)
            try write(to: url)
            documentName = url.deletingPathExtension().lastPathComponent
            rememberLastDocument()
            if !quiet { show(L("「\(url.lastPathComponent)」に保存しました")) }
            return true
        } catch {
            show(L("保存に失敗しました: \(error.localizedDescription)"))
            return false
        }
    }

    /// 「名前を付けて保存」で書いたファイルを、今の書類として扱う（以後の上書き保存先になる）
    func adoptSavedAs(_ url: URL) {
        releaseAccess()
        let scoped = url.startAccessingSecurityScopedResource()
        let inside = appFolders.contains(url)
        var sidecarError: Error?
        // サイドカーはアプリのフォルダーの中でだけ書く（外の場所は素の PNG）
        if inside {
            do { try writeSidecar(for: url) } catch { sidecarError = error }
        }
        editor.markSaved(url: url)
        isOutsideDocument = !inside
        if scoped { accessedURL = url }
        documentName = url.deletingPathExtension().lastPathComponent
        rememberLastDocument()
        if let sidecarError {
            show(L("「\(url.lastPathComponent)」に保存しましたが、設定（.nanodot）を書けませんでした: \(sidecarError.localizedDescription)"))
        } else if inside {
            show(L("「\(url.lastPathComponent)」に保存しました"))
        } else {
            show(L("「\(url.lastPathComponent)」に保存しました。アプリのフォルダーの外なので、素の PNG として扱います"))
        }
    }

    /// アプリを離れるとき、アプリのフォルダーの書類だけ自動で保存する（外の場所のファイルは勝手に上書きしない）
    func autosave() {
        guard editor.isDirty, !editor.isEditing else { return }
        if let u = editor.fileURL, !appFolders.contains(u) { return }
        save(quiet: true)
    }

    /// 外の場所の書類を、アプリの書類フォルダーに複製して、そちらを開いた状態にする（いまの絵を新しい PNG として書く）。
    /// 元の書類には触らない。元の隣にサイドカーがあっても、それは読めないので付いてこない
    @discardableResult
    func duplicateIntoAppFolder() -> Bool {
        do {
            let url = uniqueURL(name: documentName)
            try write(to: url)
            releaseAccess()
            isOutsideDocument = false
            documentName = url.deletingPathExtension().lastPathComponent
            rememberLastDocument()
            show(L("「このiPad内 › Nanodot」に「\(url.lastPathComponent)」を作りました"))
            return true
        } catch {
            show(L("複製に失敗しました: \(error.localizedDescription)"))
            return false
        }
    }

    private func uniqueURL(name: String) -> URL {
        let dir = Self.documentsDirectory
        var url = dir.appendingPathComponent(name + ".png")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) \(i).png")
            i += 1
        }
        return url
    }

    private func write(to url: URL) throws {
        guard let png = SheetFile.pngData(editor.image) else { throw SheetFileError.encodeFailed }
        try CoordinatedFile.write(png, to: url)
        // サイドカーはアプリのフォルダーの中でだけ書く。外の場所では隣に手を出せないので、素の PNG だけを書く
        let inside = appFolders.contains(url)
        if inside { try writeSidecar(for: url) }
        editor.markSaved(url: url)
        isOutsideDocument = !inside
    }

    private func writeSidecar(for url: URL) throws {
        try RelatedFile.write(try SheetFile.encodeMeta(editor.meta), to: SheetFile.sidecarURL(for: url), primary: url)
    }

    // MARK: - 前回の書類

    /// アプリの書類フォルダーの中の書類だけ、次の起動で開き直す（iPad ではアプリが裏で終わらされることが多いため）
    private func rememberLastDocument() {
        let d = UserDefaults.standard
        guard let u = editor.fileURL, appFolders.contains(u) else {
            d.removeObject(forKey: "pad.lastDocument")
            return
        }
        // container の場所はインストールし直すと変わるので、書類フォルダーからの相対で覚える
        let base = Self.documentsDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = u.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix(base) {
            d.set(String(path.dropFirst(base.count)), forKey: "pad.lastDocument")
        } else {
            d.removeObject(forKey: "pad.lastDocument")
        }
    }

    private func restoreLastDocument() -> Bool {
        guard let rel = UserDefaults.standard.string(forKey: "pad.lastDocument") else { return false }
        let url = Self.documentsDirectory.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        open(url: url)
        return editor.fileURL != nil
    }

    // MARK: - 書き出し

    /// 書き出す PNG（scale 倍に拡大）
    func pngData(scale: Int) -> Data? {
        SheetFile.pngData(editor.image.scaled(max(1, scale)))
    }

    /// 選んだアニメを GIF / APNG にして一時ファイルに書く（共有シートで渡す）
    func exportAnimFile(_ format: AnimExport.Format, scale: Int) -> URL? {
        guard let anim = editor.meta.anims.first(where: { $0.id == selectedAnimID }) else { return nil }
        let frames = AnimExport.frames(of: anim, in: editor.image, scale: scale)
        guard !frames.isEmpty else {
            show(L("コマがありません"))
            return nil
        }
        let base = anim.name.isEmpty ? "anim" : anim.name
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            switch format {
            case .gif:
                let url = dir.appendingPathComponent(base + ".gif")
                try AnimExport.writeGIF(frames, to: url)
                return url
            case .apng:
                let url = dir.appendingPathComponent(base + ".png")
                try AnimExport.writeAPNG(frames, to: url)
                return url
            case .pngSequence:
                // 連番はフォルダーごと渡す
                let folder = dir.appendingPathComponent(base, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try AnimExport.writePNGSequence(frames, directory: folder, baseName: base)
                return folder
            }
        } catch {
            show(L("書き出しに失敗しました: \(error.localizedDescription)"))
            return nil
        }
    }

    /// シートを PNG にして一時ファイルに書く（共有シートで渡す）
    func sheetShareFile(scale: Int) -> URL? {
        guard let data = pngData(scale: scale) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = scale > 1 ? "\(documentName)@\(scale)x.png" : "\(documentName).png"
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url
        } catch {
            show(L("書き出しに失敗しました: \(error.localizedDescription)"))
            return nil
        }
    }
}

/// サイドカーを読み書きできる場所（アプリの書類フォルダーと iCloud container）
struct AppFolders {
    var roots: [URL]

    /// url がアプリのフォルダーの中（下の階層も含む）にあるか
    func contains(_ url: URL) -> Bool {
        let path = Self.normalized(url)
        return roots.contains { root in
            let r = Self.normalized(root)
            return path.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
    }

    /// /var と /private/var のような見かけの違いをそろえる
    private static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// iCloud Drive やほかのアプリの場所のファイルを、調停（NSFileCoordinator）を通して読み書きする
enum CoordinatedFile {
    static func read(_ url: URL) throws -> Data {
        try coordinate(url, write: nil) { try Data(contentsOf: $0) }
    }

    static func write(_ data: Data, to url: URL) throws {
        try coordinate(url, write: .forReplacing) { u in
            do { try data.write(to: u, options: .atomic) } catch { try data.write(to: u) }
        }
    }

    private static func coordinate<T>(_ url: URL, write: NSFileCoordinator.WritingOptions?, _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        if let write {
            coordinator.coordinate(writingItemAt: url, options: write, error: &coordinationError) { u in result = Result { try body(u) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { u in result = Result { try body(u) } }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}

/// 書き出し（ファイル App の保存先を選ぶ）用のファイル
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
