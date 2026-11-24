import AppKit
import NanodotCore
import Observation
import UniformTypeIdentifiers

@Observable
final class AppState {
    let editor = Editor()
    /// カーソル下のドット（ステータスバー表示用）
    var cursorDot: IntPoint?
    var showNewDocumentSheet = false
    /// ストックの表示倍率（パネルの表示用。実体は StockView）
    var stockZoom: CGFloat = 1
    var selectedAnimID: UUID?
    /// 右ドラッグをドラッグとみなすまでの移動ドット数
    var dragThreshold: Int = UserDefaults.standard.object(forKey: "dragThreshold") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(dragThreshold, forKey: "dragThreshold") }
    }

    /// アニメウィンドウが開いているか（オニオンスキンの表示条件）
    var animWindowVisible = false
    var onionSkin: Bool = UserDefaults.standard.object(forKey: "onionSkin") as? Bool ?? true {
        didSet { UserDefaults.standard.set(onionSkin, forKey: "onionSkin") }
    }
    /// ストックとマップにセルの注釈を重ねて表示
    var showAnnotations: Bool = UserDefaults.standard.object(forKey: "showAnnotations") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showAnnotations, forKey: "showAnnotations") }
    }

    // MARK: マップ
    /// マップの仮組みの編集状態（NanodotCore。iPad 版と共有）
    let mapSession: MapSession
    @ObservationIgnored weak var mapView: MapCanvasView?

    @ObservationIgnored weak var mainView: MainCanvasView?
    @ObservationIgnored weak var stockView: StockView?
    @ObservationIgnored weak var previewView: AnimPreviewView?
    /// アニメプレビューで表示中のコマ（ストックに枠を出す）
    @ObservationIgnored var previewFrameRect: IntRect?
    /// 点滅の表示相
    @ObservationIgnored private(set) var blinkOn = false
    @ObservationIgnored private var blinkTimer: Timer?
    @ObservationIgnored private var imageCache: (version: Int, image: CGImage)?
    @ObservationIgnored private var clipboardChangeCount = -1

    #if !APPSTORE
    // MARK: MCP
    var mcpEnabled: Bool = UserDefaults.standard.bool(forKey: "mcpEnabled") {
        didSet {
            UserDefaults.standard.set(mcpEnabled, forKey: "mcpEnabled")
            updateMCP()
        }
    }
    var mcpPort: Int = UserDefaults.standard.object(forKey: "mcpPort") as? Int ?? 47621 {
        didSet {
            UserDefaults.standard.set(mcpPort, forKey: "mcpPort")
            if mcpEnabled { updateMCP() }
        }
    }
    var mcpStatus = MCPHTTPServer.Status.stopped
    @ObservationIgnored private var mcpHTTP: MCPHTTPServer?

    var mcpURL: String { "http://127.0.0.1:\(mcpPort)/mcp" }
    #endif

    init() {
        editor.newDocument(width: 256, height: 256, cellWidth: 32, cellHeight: 32)
        mapSession = MapSession(editor: editor)
        mapSession.onChange = { [weak self] in self?.mapView?.needsDisplay = true }
        editor.onPixelsChanged = { [weak self] in self?.requestDisplay() }
        #if !APPSTORE
        updateMCP()
        #endif
    }

    #if !APPSTORE
    private func updateMCP() {
        guard mcpEnabled else {
            mcpHTTP?.stop()
            return
        }
        if mcpHTTP == nil {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            let server = NanodotMCP.server(host: self, version: version)
            let http = MCPHTTPServer { [weak self] data in
                let out = server.handle(data)
                self?.requestDisplay()
                return out
            }
            http.onStatus = { [weak self] s in self?.mcpStatus = s }
            mcpHTTP = http
        }
        mcpHTTP?.start(port: UInt16(clamping: mcpPort))
    }

    /// MCP から開く・新規にしたとき
    func sheetReplaced() {
        selectedAnimID = editor.meta.anims.first?.id
        mapSession.sheetReplaced()
        stockView?.fitToView()
        requestDisplay()
    }
    #endif

    var title: String {
        let name = editor.fileURL?.lastPathComponent ?? L("無題")
        return editor.isDirty ? name + L(" — 編集済み") : name
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
        mainView?.needsDisplay = true
        stockView?.needsDisplay = true
        previewView?.needsDisplay = true
        mapView?.needsDisplay = true
    }

    /// その色を使っている場所を少しの間点滅させる（パレットの右クリックメニューから）
    func flashHighlight(_ c: RGBA) {
        editor.highlight = c
        blinkTimer?.invalidate()
        blinkOn = true
        var ticks = 0
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            ticks += 1
            self.blinkOn.toggle()
            if ticks >= 8 {
                t.invalidate()
                self.blinkTimer = nil
                self.blinkOn = false
                self.editor.highlight = nil
            }
            self.mainView?.needsDisplay = true
            self.stockView?.needsDisplay = true
        }
        mainView?.needsDisplay = true
        stockView?.needsDisplay = true
    }

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

    // MARK: - マップ

    /// シートの列数（セル番号の計算に使う）
    var sheetColumns: Int { mapSession.sheetColumns }

    /// セル番号の画像（画素が変わったら作り直す）
    func cellImage(_ index: Int) -> CGImage? { mapSession.cellImage(index, sheet: sheetImage) }

    var isMapWindowKey: Bool {
        guard let w = mapView?.window else { return false }
        return NSApp.keyWindow === w
    }

    // MARK: - クリップボード

    /// 内部のクリップボードに置き、システムのクリップボードにも PNG で書く
    func setClipboard(_ b: PixelBuffer) {
        editor.setClipboard(b)
        guard let data = SheetFile.pngData(b) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        clipboardChangeCount = pb.changeCount
    }

    /// 選択範囲（なければマーク範囲）をコピー
    func copyMark() {
        if let b = editor.copy(editor.targetRect) { setClipboard(b) }
    }

    /// 選択範囲（なければマーク範囲）を切り取る
    func cutMark() {
        guard !editor.isEditing, let b = editor.cut(editor.targetRect) else { return }
        setClipboard(b)
    }

    /// 矢印キー: 選択範囲があれば中身を 1 ドット（Shift で 8 ドット）動かし、なければマーク位置を動かす
    func arrowKey(dx: Int, dy: Int, shift: Bool) {
        if editor.selection != nil {
            let n = shift ? 8 : 1
            editor.nudgeSelection(dx: dx * n, dy: dy * n)
            requestDisplay()
        } else {
            moveMark(dx: dx, dy: dy, byLupe: shift)
        }
    }

    /// 他のアプリで画像がコピーされていればそれを取り込んでスタンプモードへ
    func pasteToStamp() {
        let pb = NSPasteboard.general
        if pb.changeCount != clipboardChangeCount {
            if let data = pb.data(forType: .png), let b = SheetFile.pixelBuffer(pngData: data) {
                editor.setClipboard(b)
            } else if let img = NSImage(pasteboard: pb), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let b = SheetFile.pixelBuffer(from: cg) {
                editor.setClipboard(b)
            }
            clipboardChangeCount = pb.changeCount
        }
        if editor.clipboard != nil { editor.stampActive = true }
        requestDisplay()
    }

    // MARK: - ファイル

    func confirmDiscardChanges() -> Bool {
        guard editor.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L("変更が保存されていません")
        alert.informativeText = L("現在のシートの変更を破棄しますか？")
        alert.addButton(withTitle: L("破棄"))
        alert.addButton(withTitle: L("キャンセル"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func newDocument(width: Int, height: Int, cellWidth: Int, cellHeight: Int) {
        editor.newDocument(width: width, height: height, cellWidth: cellWidth, cellHeight: cellHeight)
        selectedAnimID = nil
        mapSession.sheetReplaced()
        stockView?.fitToView()
        requestDisplay()
    }

    func open() {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .gif, .bmp, .tiff, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        // サイドカー（<名前>.nanodot）を渡されたら、隣の PNG を開く
        let url = url.pathExtension.lowercased() == SheetFile.sidecarExtension ? url.deletingPathExtension().appendingPathExtension("png") : url
        do {
            let (img, meta) = try SheetFile.load(url: url)
            let isPNG = url.pathExtension.lowercased() == "png"
            var m = meta ?? SheetMeta()
            if meta == nil { m.slots = editor.meta.slots }
            // PNG 以外は上書き保存しない（保存時に PNG の名前を聞く）
            editor.load(img, meta: m, url: isPNG ? url : nil)
            selectedAnimID = m.anims.first?.id
            mapSession.sheetReplaced()
            stockView?.fitToView()
            requestDisplay()
        } catch {
            showError(L("ファイルを開けませんでした: \(error.localizedDescription)"))
        }
    }

    /// ウィンドウにドロップされたファイルを開く
    @discardableResult
    func openDropped(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: { ["png", "gif", "bmp", "tif", "tiff", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }) else {
            return false
        }
        // ドラッグ操作の途中でモーダルを出さないよう、次のランループで処理する
        DispatchQueue.main.async { [self] in
            NSApp.activate(ignoringOtherApps: true)
            guard confirmDiscardChanges() else { return }
            open(url: url)
        }
        return true
    }

    func save() {
        editor.commitSelection()
        if let url = editor.fileURL { write(to: url) } else { saveAs() }
    }

    func saveAs() {
        editor.commitSelection()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = editor.fileURL?.deletingPathExtension().lastPathComponent ?? L("無題")
        panel.message = L("設定は同じフォルダーの <名前>.nanodot に保存されます")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        do {
            try SheetFile.save(editor.image, meta: editor.meta, url: url)
            editor.markSaved(url: url)
        } catch {
            showError(L("保存に失敗しました: \(error.localizedDescription)"))
        }
    }

    // MARK: - 書き出し・読み込み（保存とは別に、明示的に行う）

    /// 前回の書き出し先フォルダーのブックマーク（シートのパスごと。マシンごとのものなのでサイドカーには入れない）
    private var exportFolderKey: String { editor.fileURL?.path ?? "" }

    /// 前回ゲームエンジン用データを書き出したフォルダー
    var lastExportFolder: URL? {
        (UserDefaults.standard.dictionary(forKey: "exportFolders")?[exportFolderKey] as? Data).flatMap(ExportFolder.resolve)
    }

    private func rememberExportFolder(_ dir: URL) {
        guard let b = try? ExportFolder.bookmark(for: dir) else { return }
        var d = UserDefaults.standard.dictionary(forKey: "exportFolders") ?? [:]
        d[exportFolderKey] = b
        UserDefaults.standard.set(d, forKey: "exportFolders")
    }

    /// フォルダーを選んでゲームエンジン用データ（アトラス JSON・Tiled マップ）を書き出す
    func exportEngineData() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("書き出し")
        let base = (editor.imageName as NSString).deletingPathExtension
        panel.message = L("\(base).atlas.json と \(base).<マップ名>.tmj を書き出すフォルダーを選択（\(editor.imageName) と同じ場所に置くと、そのまま読めます）")
        panel.directoryURL = lastExportFolder ?? editor.fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        writeEngineData(to: dir)
    }

    /// 前回の書き出し先にもう一度書き出す（なければフォルダーを選ぶ）
    func exportEngineDataAgain() {
        if let dir = lastExportFolder { writeEngineData(to: dir) } else { exportEngineData() }
    }

    private func writeEngineData(to dir: URL) {
        do {
            let names = try EngineExport.write(imageName: editor.imageName, width: editor.image.width, height: editor.image.height,
                                               meta: editor.meta, to: dir)
            if names.isEmpty {
                showError(L("書き出すものがありません（アニメ・名前付きセル・マップがありません）"))
            } else {
                rememberExportFolder(dir)
            }
        } catch {
            showError(L("書き出しに失敗しました: \(error.localizedDescription)"))
        }
    }

    /// 設定のファイル（<名前>.nanodot や古い名前の <名前>.nanodot.json）を選んで、今のシートに読み込む。
    /// Sandbox では古い名前のサイドカーを自動では読めないので、その移行に使う
    func importMeta() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json] + [UTType(filenameExtension: SheetFile.sidecarExtension)].compactMap { $0 }
        panel.directoryURL = editor.fileURL?.deletingLastPathComponent()
        panel.message = L("設定のファイル（<名前>.nanodot、古い <名前>.nanodot.json）を選択。今のシートの設定を置き換えます")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let meta = SheetFile.decodeMeta(data) else {
            showError(L("設定を読み込めませんでした"))
            return
        }
        editor.meta = meta
        editor.setMark(editor.meta.mark)
        selectedAnimID = meta.anims.first?.id
        mapSession.sheetReplaced()
        requestDisplay()
    }

    func exportAnim(_ format: AnimExport.Format, scale: Int) {
        guard let anim = editor.meta.anims.first(where: { $0.id == selectedAnimID }) else { return }
        let frames = AnimExport.frames(of: anim, in: editor.image, scale: scale)
        guard !frames.isEmpty else {
            showError(L("コマがありません"))
            return
        }
        let baseName = anim.name.isEmpty ? "anim" : anim.name
        do {
            switch format {
            case .gif, .apng:
                let panel = NSSavePanel()
                panel.allowedContentTypes = [format == .gif ? .gif : .png]
                panel.nameFieldStringValue = baseName
                guard panel.runModal() == .OK, let url = panel.url else { return }
                if format == .gif { try AnimExport.writeGIF(frames, to: url) } else { try AnimExport.writeAPNG(frames, to: url) }
            case .pngSequence:
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = L("書き出し")
                panel.message = L("\(baseName)_000.png, \(baseName)_001.png … を書き出すフォルダーを選択")
                guard panel.runModal() == .OK, let dir = panel.url else { return }
                try AnimExport.writePNGSequence(frames, directory: dir, baseName: baseName)
            }
        } catch {
            showError(L("書き出しに失敗しました: \(error.localizedDescription)"))
        }
    }

    func showSheetSizeDialog() {
        let alert = NSAlert()
        alert.messageText = L("シートサイズ")
        alert.informativeText = L("左上を基準に変更します（幅 × 高さ）")
        let w = NSTextField(string: "\(editor.image.width)")
        let h = NSTextField(string: "\(editor.image.height)")
        w.frame = NSRect(x: 0, y: 30, width: 120, height: 24)
        h.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 54))
        box.addSubview(w)
        box.addSubview(h)
        alert.accessoryView = box
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L("キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn, let nw = Int(w.stringValue), let nh = Int(h.stringValue) else { return }
        editor.resizeSheet(width: min(max(nw, 1), 8192), height: min(max(nh, 1), 8192))
        requestDisplay()
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}

#if !APPSTORE
extension AppState: MCPHost {}
#endif
