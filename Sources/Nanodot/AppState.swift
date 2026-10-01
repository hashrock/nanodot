import AppKit
import NanodotCore
import Observation
import UniformTypeIdentifiers

@Observable
final class AppState: MCPHost {
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
    var selectedMapID: UUID?
    var mapLayer = 0
    var mapTool = MapTool.pen
    /// マップで右クリック・右ドラッグで拾ったブラシ（なければマーク範囲のセル）
    var mapBrushOverride: MapBrush?
    var canMapUndo = false
    var canMapRedo = false
    @ObservationIgnored weak var mapView: MapCanvasView?
    @ObservationIgnored private var mapUndoStack: [(id: UUID, map: TileMapDef)] = []
    @ObservationIgnored private var mapRedoStack: [(id: UUID, map: TileMapDef)] = []
    @ObservationIgnored private var cellImageCache: (version: Int, cw: Int, ch: Int, images: [Int: CGImage]) = (-1, 0, 0, [:])

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

    init() {
        editor.newDocument(width: 256, height: 256, cellWidth: 32, cellHeight: 32)
        editor.onPixelsChanged = { [weak self] in self?.requestDisplay() }
        updateMCP()
    }

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
        selectedMapID = editor.meta.maps.first?.id
        mapLayer = 0
        mapBrushOverride = nil
        resetMapHistory()
        stockView?.fitToView()
        requestDisplay()
    }

    var title: String {
        let name = editor.fileURL?.lastPathComponent ?? "無題"
        return editor.isDirty ? name + " — 編集済み" : name
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

    /// パレットで色を押している間、その色の場所を点滅させる
    func setHighlight(_ c: RGBA?) {
        editor.highlight = c
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = c != nil
        if c != nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.blinkOn.toggle()
                self.mainView?.needsDisplay = true
                self.stockView?.needsDisplay = true
            }
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
    var sheetColumns: Int { max(1, editor.image.width / max(1, editor.meta.cellWidth)) }

    /// マーク範囲にかかるセルをブラシにしたもの
    var markBrush: MapBrush {
        let m = editor.meta, cw = max(1, m.cellWidth), ch = max(1, m.cellHeight)
        let c0 = m.mark.x / cw, r0 = m.mark.y / ch
        let c1 = max(c0, (m.mark.x + m.lupeWidth - 1) / cw), r1 = max(r0, (m.mark.y + m.lupeHeight - 1) / ch)
        let cols = sheetColumns, rows = max(1, editor.image.height / ch)
        var tiles: [Int] = []
        for r in r0...r1 {
            for c in c0...c1 { tiles.append(c < cols && r < rows ? SheetMeta.cellIndex(col: c, row: r, columns: cols) : -1) }
        }
        return MapBrush(width: c1 - c0 + 1, height: r1 - r0 + 1, tiles: tiles)
    }

    var mapBrush: MapBrush { mapBrushOverride ?? markBrush }

    /// セル番号の画像（画素が変わったら作り直す）
    func cellImage(_ index: Int) -> CGImage? {
        guard index >= 0, let sheet = sheetImage else { return nil }
        let cw = editor.meta.cellWidth, ch = editor.meta.cellHeight
        if cellImageCache.version != editor.pixelVersion || cellImageCache.cw != cw || cellImageCache.ch != ch {
            cellImageCache = (editor.pixelVersion, cw, ch, [:])
        }
        if let img = cellImageCache.images[index] { return img }
        let (c, r) = SheetMeta.cellPosition(index, columns: sheetColumns)
        let rect = IntRect(x: c * cw, y: r * ch, width: cw, height: ch).intersection(editor.image.bounds)
        guard !rect.isEmpty, let img = Draw.crop(sheet, rect) else { return nil }
        cellImageCache.images[index] = img
        return img
    }

    var isMapWindowKey: Bool {
        guard let w = mapView?.window else { return false }
        return NSApp.keyWindow === w
    }

    var mapIndex: Int? { editor.meta.maps.firstIndex { $0.id == selectedMapID } }

    /// マップ編集の取り消し点を記録する（ドラッグ 1 回につき 1 回）
    func beginMapEdit() {
        guard let i = mapIndex else { return }
        let m = editor.meta.maps[i]
        mapUndoStack.append((m.id, m))
        if mapUndoStack.count > 100 { mapUndoStack.removeFirst() }
        mapRedoStack.removeAll()
        updateMapHistory()
    }

    func mutateMap(_ body: (inout TileMapDef) -> Void) {
        guard let i = mapIndex else { return }
        body(&editor.meta.maps[i])
        mapView?.needsDisplay = true
    }

    func mapUndo() { swapMapHistory(from: &mapUndoStack, to: &mapRedoStack) }
    func mapRedo() { swapMapHistory(from: &mapRedoStack, to: &mapUndoStack) }

    private func swapMapHistory(from: inout [(id: UUID, map: TileMapDef)], to: inout [(id: UUID, map: TileMapDef)]) {
        guard let e = from.popLast(), let i = editor.meta.maps.firstIndex(where: { $0.id == e.id }) else {
            updateMapHistory()
            return
        }
        to.append((e.id, editor.meta.maps[i]))
        editor.meta.maps[i] = e.map
        selectedMapID = e.id
        mapLayer = min(mapLayer, e.map.layers.count - 1)
        updateMapHistory()
        mapView?.needsDisplay = true
    }

    private func updateMapHistory() {
        canMapUndo = !mapUndoStack.isEmpty
        canMapRedo = !mapRedoStack.isEmpty
    }

    func resetMapHistory() {
        mapUndoStack.removeAll()
        mapRedoStack.removeAll()
        updateMapHistory()
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

    func copyMark() {
        if let b = editor.copy(editor.markRect) { setClipboard(b) }
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
        alert.messageText = "変更が保存されていません"
        alert.informativeText = "現在のシートの変更を破棄しますか？"
        alert.addButton(withTitle: "破棄")
        alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func newDocument(width: Int, height: Int, cellWidth: Int, cellHeight: Int) {
        editor.newDocument(width: width, height: height, cellWidth: cellWidth, cellHeight: cellHeight)
        selectedAnimID = nil
        selectedMapID = nil
        resetMapHistory()
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
        do {
            let (img, meta) = try SheetFile.load(url: url)
            let isPNG = url.pathExtension.lowercased() == "png"
            var m = meta ?? SheetMeta()
            if meta == nil { m.slots = editor.meta.slots }
            // PNG 以外は上書き保存しない（保存時に PNG の名前を聞く）
            editor.load(img, meta: m, url: isPNG ? url : nil)
            selectedAnimID = m.anims.first?.id
            selectedMapID = m.maps.first?.id
            mapLayer = 0
            mapBrushOverride = nil
            resetMapHistory()
            stockView?.fitToView()
            requestDisplay()
        } catch {
            showError("ファイルを開けませんでした: \(error.localizedDescription)")
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
        if let url = editor.fileURL { write(to: url) } else { saveAs() }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = editor.fileURL?.deletingPathExtension().lastPathComponent ?? "無題"
        panel.message = "設定は同じフォルダーの <名前>.nanodot.json に保存されます"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        do {
            try SheetFile.save(editor.image, meta: editor.meta, url: url)
            editor.markSaved(url: url)
        } catch {
            showError("保存に失敗しました: \(error.localizedDescription)")
        }
    }

    func exportAnim(_ format: AnimExport.Format, scale: Int) {
        guard let anim = editor.meta.anims.first(where: { $0.id == selectedAnimID }) else { return }
        let frames = AnimExport.frames(of: anim, in: editor.image, scale: scale)
        guard !frames.isEmpty else {
            showError("コマがありません")
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
                panel.prompt = "書き出し"
                panel.message = "\(baseName)_000.png, \(baseName)_001.png … を書き出すフォルダーを選択"
                guard panel.runModal() == .OK, let dir = panel.url else { return }
                try AnimExport.writePNGSequence(frames, directory: dir, baseName: baseName)
            }
        } catch {
            showError("書き出しに失敗しました: \(error.localizedDescription)")
        }
    }

    func showSheetSizeDialog() {
        let alert = NSAlert()
        alert.messageText = "シートサイズ"
        alert.informativeText = "左上を基準に変更します（幅 × 高さ）"
        let w = NSTextField(string: "\(editor.image.width)")
        let h = NSTextField(string: "\(editor.image.height)")
        w.frame = NSRect(x: 0, y: 30, width: 120, height: 24)
        h.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 54))
        box.addSubview(w)
        box.addSubview(h)
        alert.accessoryView = box
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
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
