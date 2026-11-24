import NanodotCore
import SwiftUI
import UniformTypeIdentifiers

/// 横のパネル（色・アニメ・マップ）。狭いときはストックもここに入る
enum SidePanel: String, CaseIterable, Identifiable {
    case stock, colors, anim, map
    var id: Self { self }

    var title: String {
        switch self {
        case .stock: return L("ストック")
        case .colors: return L("色")
        case .anim: return L("アニメ")
        case .map: return L("マップ")
        }
    }
}

/// ツールバーに並べるもの: 描くツールと、iPad 版だけのスポイト（描くツールの上に重ねるモード）
enum PadTool: Hashable {
    case draw(Tool)
    case eyedropper

    /// 並び順（テキストは入れていない）
    static let all: [PadTool] = [.draw(.pen), .draw(.eraser), .draw(.fill), .eyedropper, .draw(.line), .draw(.rect), .draw(.ellipse), .draw(.select)]

    var displayName: String {
        switch self {
        case .draw(let t): return t.displayName
        case .eyedropper: return L("スポイト (I)")
        }
    }

    var symbol: String {
        switch self {
        case .draw(let t): return t.symbol
        case .eyedropper: return "eyedropper"
        }
    }
}

struct PadContentView: View {
    let state: PadState
    @Bindable var editor: Editor
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("pad.sidePanel") private var sidePanelRaw = SidePanel.colors.rawValue
    @State private var dropTargeted = false
    @State private var showNewDocument = false
    @State private var showSettings = false
    @State private var showOutsideInfo = false
    @State private var importing = false
    @State private var exportFile: ExportFile?
    @State private var showExporter = false
    /// 書き出しではなく「名前を付けて保存」として保存先を選んでいる
    @State private var savingAs = false
    @State private var shareURL: URL?
    @State private var confirmDiscard: PendingAction?

    enum PendingAction: Hashable, Identifiable {
        /// ドロップされたファイル。scoped なら開いたあとアクセス権を手放す
        case openFile(URL, scoped: Bool)
        case new, open
        var id: Self { self }
    }

    init(state: PadState) {
        self.state = state
        editor = state.editor
    }

    private var sidePanel: SidePanel {
        get { SidePanel(rawValue: sidePanelRaw) ?? .colors }
        nonmutating set { sidePanelRaw = newValue.rawValue }
    }

    var body: some View {
        GeometryReader { geo in
            layout(geo.size)
        }
        .safeAreaInset(edge: .top, spacing: 0) { toolbar }
        .overlay(alignment: .bottom) { toast }
        .overlay {
            if dropTargeted {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .background { KeyboardShortcuts(state: state, editor: editor, actions: shortcutActions) }
        .onDrop(of: PadState.openableTypes, isTargeted: $dropTargeted) { providers in
            state.receiveDropped(providers) { url, scoped in requestDiscard(.openFile(url, scoped: scoped)) }
        }
        .sheet(isPresented: $showNewDocument) {
            NewDocumentSheet { w, h, cw, ch in state.newDocument(width: w, height: h, cellWidth: cw, cellHeight: ch) }
        }
        .sheet(item: $shareURL) { url in ActivityView(items: [url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: PadState.openableTypes) { result in
            if case let .success(url) = result { state.open(url: url) }
        }
        .fileExporter(isPresented: $showExporter, document: exportFile, contentType: .png,
                      defaultFilename: state.documentName) { result in
            if case let .success(url) = result {
                if savingAs { state.adoptSavedAs(url) } else { state.show(L("「\(url.lastPathComponent)」に書き出しました")) }
            }
            exportFile = nil
        }
        .confirmationDialog("変更が保存されていません", isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
                            titleVisibility: .visible, presenting: confirmDiscard) { action in
            Button("保存してから続ける") {
                if state.save() { perform(action) }
            }
            Button("変更を破棄", role: .destructive) { perform(action) }
            Button("キャンセル", role: .cancel) {
                if case let .openFile(url, scoped: true) = action { url.stopAccessingSecurityScopedResource() }
            }
        }
        .onOpenURL { url in requestDiscard(.openFile(url, scoped: false)) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { state.autosave() }
            if phase == .active { state.refreshFingerDrawingDefault() }
        }
        .onChange(of: state.showColorsRequest) { _, _ in
            if sidePanel == .anim { sidePanel = .colors }
        }
        .onChange(of: state.isOutsideDocument) { _, outside in
            if outside && !savingAs { state.show(L("アプリのフォルダーの外の書類です。素の PNG として開きました")) }
        }
        // ストックでマーク位置を選び直したら、マップで拾ったブラシをやめてマーク範囲のセルに戻す（Mac 版と同じ）
        .onChange(of: editor.meta.mark) { _, _ in state.mapSession.brushOverride = nil }
        .onChange(of: editor.meta.lupeWidth) { _, _ in state.mapSession.brushOverride = nil }
        .onChange(of: editor.meta.lupeHeight) { _, _ in state.mapSession.brushOverride = nil }
    }

    // MARK: - 画面の構成

    /// 横長で広い: メイン ｜ ストック＋パネル（縦に並べる）
    /// 縦長: メインの下に ストック ｜ パネル
    /// 狭い（Split View など）: メインの下に、ストック・色・アニメを切り替えて出す
    @ViewBuilder
    private func layout(_ size: CGSize) -> some View {
        let narrow = size.width < 620
        let wide = !narrow && size.width > size.height * 0.95
        if wide {
            HStack(spacing: 0) {
                canvas
                Divider()
                VStack(spacing: 0) {
                    stockArea
                    Divider()
                    panelArea(choices: sideChoices)
                        .frame(height: min(470, size.height * 0.62))
                }
                .frame(width: min(400, max(320, size.width * 0.3)))
            }
            .onAppear { normalizeSidePanel(narrow: false) }
        } else if !narrow {
            VStack(spacing: 0) {
                canvas
                Divider()
                HStack(spacing: 0) {
                    stockArea
                    Divider()
                    panelArea(choices: sideChoices)
                        .frame(width: min(420, size.width * 0.48))
                }
                .frame(height: size.height * 0.42)
            }
            .onAppear { normalizeSidePanel(narrow: false) }
        } else {
            VStack(spacing: 0) {
                canvas
                Divider()
                panelArea(choices: state.mapMode ? [.map, .stock] : [.stock, .colors, .anim])
                    .frame(height: size.height * 0.46)
            }
        }
    }

    /// メインの場所: ふだんはメイン、マップを出しているときはマップ
    @ViewBuilder
    private var canvas: some View {
        if state.mapMode {
            MapCanvasRepresentable(state: state)
        } else {
            MainCanvasRepresentable(state: state)
        }
    }

    /// ストックの隣のパネル（マップを出している間はマップのパネルだけ）
    private var sideChoices: [SidePanel] { state.mapMode ? [.map] : [.colors, .anim] }

    private func normalizeSidePanel(narrow: Bool) {
        if !narrow && sidePanel == .stock { sidePanel = .colors }
    }

    private var stockArea: some View {
        VStack(spacing: 0) {
            StockRepresentable(state: state)
            Divider()
            StockBar(state: state, editor: editor)
        }
        .onAppear { if sidePanel == .stock { state.animPanelVisible = false } }
    }

    private func panelArea(choices: [SidePanel]) -> some View {
        let current = choices.contains(sidePanel) ? sidePanel : choices[0]
        return VStack(spacing: 0) {
            if choices.count > 1 {
                Picker("パネル", selection: Binding(get: { current }, set: { sidePanel = $0 })) {
                    ForEach(choices) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
            } else {
                Text(current.title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .padding(10)
                    .accessibilityAddTraits(.isHeader)
            }
            Divider()
            switch current {
            case .stock:
                stockArea
            case .colors:
                ScrollView { ColorPanel(state: state, editor: editor).padding(12) }
            case .anim:
                ScrollView { AnimPanel(state: state, editor: editor).padding(12) }
            case .map:
                ScrollView { MapPanel(state: state, editor: editor).padding(12) }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { state.animPanelVisible = current == .anim }
        .onChange(of: current) { _, new in
            state.animPanelVisible = new == .anim
            state.requestDisplay()
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let t = state.toast {
            Text(t)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .transition(.opacity)
                .padding(.bottom, 24)
                .allowsHitTesting(false)
        }
    }

    // MARK: - ファイル

    private func requestDiscard(_ action: PendingAction) {
        if editor.isDirty { confirmDiscard = action } else { perform(action) }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case .new: showNewDocument = true
        case .open: importing = true
        case let .openFile(url, scoped):
            state.open(url: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    private func exportPNG(scale: Int, saveAs: Bool = false) {
        guard let data = state.pngData(scale: scale) else {
            state.show(L("画像を書き出せませんでした"))
            return
        }
        savingAs = saveAs
        exportFile = ExportFile(data: data)
        showExporter = true
    }

    private var shortcutActions: KeyboardShortcuts.Actions {
        KeyboardShortcuts.Actions(
            new: { requestDiscard(.new) },
            open: { requestDiscard(.open) },
            save: { state.save() },
            saveAs: { exportPNG(scale: 1, saveAs: true) },
            showAnim: {
                state.mapMode = false
                sidePanel = sidePanel == .anim ? .colors : .anim
            },
            toggleMap: { toggleMapMode() }
        )
    }

    private func toggleMapMode() {
        state.mainView?.cancelInteraction()
        state.mapView?.cancelInteraction()
        state.mapMode.toggle()
        state.requestDisplay()
    }

    // MARK: - ツールバー

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarContent(compact: false)
            toolbarContent(compact: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func toolbarContent(compact: Bool) -> some View {
        HStack(spacing: 4) {
            fileMenu
            barButton("arrow.uturn.backward", disabled: !state.canUndo) { state.undo() }
                .accessibilityLabel(state.mapMode ? L("マップの取り消し") : editor.undoLabel.map { L("取り消し: \($0)") } ?? L("取り消し"))
            barButton("arrow.uturn.forward", disabled: !state.canRedo) { state.redo() }
                .accessibilityLabel(state.mapMode ? L("マップのやり直し") : editor.redoLabel.map { L("やり直し: \($0)") } ?? L("やり直し"))

            Spacer(minLength: 6)
            titleView
            Spacer(minLength: 6)

            if state.mapMode {
                mapTools(compact: compact)
            } else if compact {
                toolMenu
            } else {
                ForEach(PadTool.all, id: \.self) { toolButton($0) }
                barButton(editor.shapeFilled ? "square.fill" : "square", selected: editor.shapeFilled,
                          disabled: editor.tool != .rect && editor.tool != .ellipse) { editor.shapeFilled.toggle() }
                    .accessibilityLabel("矩形・楕円を塗りつぶす")
                penSizeMenu
            }
            if !state.mapMode {
                // 選択範囲があるときは、マーク範囲の操作の代わりに選択範囲の操作を出す
                if editor.selection == nil { markMenu }
                selectionBar(compact: compact)
                stampButton
            }
            mapButton
            barButton("gearshape", selected: showSettings) { showSettings.toggle() }
                .accessibilityLabel("設定")
                .popover(isPresented: $showSettings) {
                    SettingsPanel(state: state, editor: editor)
                        .frame(width: 440)
                }
        }
    }

    /// マップの仮組みに切り替える（もう一度押すとメインに戻る）
    private var mapButton: some View {
        Button { toggleMapMode() } label: {
            Image(systemName: "map")
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .foregroundStyle(state.mapMode ? Color.white : Color.primary)
                .background(state.mapMode ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(state.mapMode ? L("マップを閉じる (⇧⌘M)") : L("マップの仮組み (⇧⌘M)"))
    }

    /// マップを出している間のツール（ペン・消しゴム・塗りつぶし）と表示の大きさ
    @ViewBuilder
    private func mapTools(compact: Bool) -> some View {
        let session = state.mapSession
        if compact {
            Menu {
                Picker("ツール", selection: Binding(get: { session.tool }, set: { session.tool = $0 })) {
                    ForEach(MapTool.allCases, id: \.self) { t in Label(t.displayName, systemImage: t.symbol).tag(t) }
                }
            } label: {
                Image(systemName: session.tool.symbol)
                    .font(.system(size: 18))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Color.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("ツール")
        } else {
            ForEach(MapTool.allCases, id: \.self) { t in
                let on = session.tool == t
                Button { session.tool = t } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 18))
                        .frame(width: 40, height: 40)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(t.displayName)
            }
            barButton("minus.magnifyingglass") { state.mapView?.stepZoom(-1) }.accessibilityLabel("縮小")
            barButton("plus.magnifyingglass") { state.mapView?.stepZoom(1) }.accessibilityLabel("拡大")
            barButton("arrow.up.left.and.down.right.magnifyingglass") { state.mapView?.fitToView() }.accessibilityLabel("全体を表示")
        }
    }

    private var titleView: some View {
        HStack(spacing: 6) {
            VStack(spacing: 0) {
                Text(state.documentName + (editor.isDirty ? " •" : ""))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                let m = editor.meta
                Text("マーク (\(m.mark.x), \(m.mark.y)) \(m.lupeWidth)×\(m.lupeHeight)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if state.isOutsideDocument {
                Button { showOutsideInfo = true } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .frame(width: 36, height: 30)
                        .background(Color.yellow.opacity(0.2), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("アプリのフォルダーの外にある書類です")
                .popover(isPresented: $showOutsideInfo) { outsideInfo }
            }
        }
        .layoutPriority(-1)
    }

    /// 外の場所の書類を開いているときの案内
    private var outsideInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("アプリのフォルダーの外にある書類です").font(.headline)
            Text("素の PNG として開いています。セルの大きさ・スロット・アニメなど（隣の「\(state.documentName).nanodot」の設定）は読まず、保存しても書きません。")
            Text("Nanodot のフォルダー（ファイル App の「このiPad内 › Nanodot」か「iCloud Drive › Nanodot」）に移すと全部使えます。「\(state.documentName).nanodot」があるときは、ファイル App で PNG と一緒に移してください。")
            Button {
                showOutsideInfo = false
                state.duplicateIntoAppFolder()
            } label: {
                Label("Nanodot のフォルダーに複製して開く", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            Text("複製は、いまの絵を新しい PNG として作ります。元の書類はそのまま残ります。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 360)
    }

    private var fileMenu: some View {
        Menu {
            Button { requestDiscard(.new) } label: { Label("新規…", systemImage: "doc.badge.plus") }
            Button { requestDiscard(.open) } label: { Label("開く…", systemImage: "folder") }
            Divider()
            Button { state.save() } label: { Label("保存", systemImage: "square.and.arrow.down") }
            Button { exportPNG(scale: 1, saveAs: true) } label: { Label("名前を付けて保存…", systemImage: "square.and.arrow.down.on.square") }
            Divider()
            Menu {
                ForEach([1, 2, 4, 8], id: \.self) { s in
                    Button("\(s) 倍") { exportPNG(scale: s) }
                }
            } label: { Label("PNG を書き出し…", systemImage: "photo") }
            Menu {
                ForEach([1, 2, 4, 8], id: \.self) { s in
                    Button("\(s) 倍") { shareURL = state.sheetShareFile(scale: s) }
                }
            } label: { Label("共有…", systemImage: "square.and.arrow.up") }
        } label: {
            Image(systemName: "doc")
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel("ファイル")
    }

    private var toolMenu: some View {
        Menu {
            Picker("ツール", selection: Binding(get: { currentTool }, set: { selectTool($0) })) {
                ForEach(PadTool.all, id: \.self) { t in Label(t.displayName, systemImage: t.symbol).tag(t) }
            }
            Toggle(isOn: $editor.shapeFilled) { Label("矩形・楕円を塗りつぶす", systemImage: "square.fill") }
            penSizePicker
        } label: {
            Image(systemName: currentTool.symbol)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .foregroundStyle(Color.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("ツール")
    }

    private var penSizePicker: some View {
        Picker(selection: $editor.penSize) {
            ForEach(Editor.penSizes, id: \.self) { Text(verbatim: "\($0)").tag($0) }
        } label: {
            Label("ペンと消しゴムの太さ", systemImage: "pencil.tip")
            Text(verbatim: "\(editor.penSize) px")
        }
            .pickerStyle(.menu)
    }

    private var penSizeMenu: some View {
        PenSizeButton(editor: editor)
            .disabled(editor.tool != .pen && editor.tool != .eraser)
    }

    private var markMenu: some View {
        Menu {
            Section("マーク範囲") {
                Button { state.copyMark() } label: { Label("コピー", systemImage: "doc.on.doc") }
                Button { state.pasteToStamp() } label: { Label("スタンプ（貼り付け）", systemImage: "seal") }
                Button { editor.apply(.clear) } label: { Label("消去", systemImage: "square.slash") }
                Button { editor.apply(.fill) } label: { Label("描画色で塗りつぶし", systemImage: "square.fill.on.square") }
            }
            Section {
                Button { editor.apply(.flipH) } label: { Label("左右反転", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                Button { editor.apply(.flipV) } label: { Label("上下反転", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                Button { editor.apply(.rotateCCW) } label: { Label("左に 90° 回転", systemImage: "rotate.left") }
                    .disabled(!editor.canRotate)
                Button { editor.apply(.rotateCW) } label: { Label("右に 90° 回転", systemImage: "rotate.right") }
                    .disabled(!editor.canRotate)
            }
            Section {
                Button { editor.apply(.shift(-1, 0)) } label: { Label("1 ドット左へシフト", systemImage: "arrow.left") }
                Button { editor.apply(.shift(1, 0)) } label: { Label("1 ドット右へシフト", systemImage: "arrow.right") }
                Button { editor.apply(.shift(0, -1)) } label: { Label("1 ドット上へシフト", systemImage: "arrow.up") }
                Button { editor.apply(.shift(0, 1)) } label: { Label("1 ドット下へシフト", systemImage: "arrow.down") }
            }
        } label: {
            Image(systemName: "square.dashed")
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
        }
        .accessibilityLabel("マーク範囲の操作")
    }

    /// 選択範囲があるときだけ出す操作。狭いときはメニューにまとめる
    @ViewBuilder
    private func selectionBar(compact: Bool) -> some View {
        if editor.selection != nil {
            if compact {
                Menu {
                    selectionActions
                } label: {
                    Image(systemName: "ellipsis.rectangle")
                        .font(.system(size: 18))
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("選択範囲の操作")
                floatingButtons
            } else {
                HStack(spacing: 2) {
                    barButton("doc.on.doc") { state.copyMark() }.accessibilityLabel("コピー")
                    barButton("scissors") { state.cutMark() }.accessibilityLabel("切り取り")
                    barButton("square.slash") { editor.apply(.clear) }.accessibilityLabel("消去")
                    barButton("square.fill.on.square") { editor.apply(.fill) }.accessibilityLabel("描画色で塗りつぶし")
                    barButton("arrow.left.and.right.righttriangle.left.righttriangle.right") { editor.apply(.flipH) }.accessibilityLabel("左右反転")
                    barButton("arrow.up.and.down.righttriangle.up.righttriangle.down") { editor.apply(.flipV) }.accessibilityLabel("上下反転")
                    barButton("rotate.right", disabled: !editor.canRotate) { editor.apply(.rotateCW) }.accessibilityLabel("右に 90° 回転")
                    if editor.isFloating {
                        floatingButtons
                    } else {
                        barButton("xmark.circle") { deselect() }.accessibilityLabel("選択を解除")
                    }
                }
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder
    private var selectionActions: some View {
        Section("選択範囲") {
            Button { state.copyMark() } label: { Label("コピー", systemImage: "doc.on.doc") }
            Button { state.cutMark() } label: { Label("切り取り", systemImage: "scissors") }
            Button { editor.apply(.clear) } label: { Label("消去", systemImage: "square.slash") }
            Button { editor.apply(.fill) } label: { Label("描画色で塗りつぶし", systemImage: "square.fill.on.square") }
        }
        Section {
            Button { editor.apply(.flipH) } label: { Label("左右反転", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
            Button { editor.apply(.flipV) } label: { Label("上下反転", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
            Button { editor.apply(.rotateCCW) } label: { Label("左に 90° 回転", systemImage: "rotate.left") }
                .disabled(!editor.canRotate)
            Button { editor.apply(.rotateCW) } label: { Label("右に 90° 回転", systemImage: "rotate.right") }
                .disabled(!editor.canRotate)
        }
        Button { deselect() } label: { Label("選択を解除", systemImage: "xmark.circle") }
    }

    /// 中身を動かして浮かせている間だけ出す: キャンセル（持ち上げる前に戻す）と確定
    @ViewBuilder
    private var floatingButtons: some View {
        if editor.isFloating {
            barButton("xmark") {
                editor.cancelSelection()
                state.requestDisplay()
            }
            .accessibilityLabel("キャンセル")
            Button {
                editor.commitSelection()
                state.requestDisplay()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Color.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("確定")
        }
    }

    private func deselect() {
        editor.setSelection(nil)
        state.requestDisplay()
    }

    /// スタンプモードの間だけ出す（透明部分を抜くかの切り替えと、抜ける）
    @ViewBuilder
    private var stampButton: some View {
        if editor.stampActive {
            HStack(spacing: 2) {
                barButton(state.stampSkipTransparent ? "seal.fill" : "seal", selected: true) {
                    state.stampSkipTransparent.toggle()
                    state.show(state.stampSkipTransparent ? L("スタンプ: 透明部分を抜く") : L("スタンプ: 透明部分も上書き"))
                }
                .accessibilityLabel("透明部分を抜く")
                barButton("xmark.circle") {
                    editor.stampActive = false
                    state.requestDisplay()
                }
                .accessibilityLabel("スタンプモードを抜ける")
            }
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var currentTool: PadTool {
        state.eyedropperActive ? .eyedropper : .draw(editor.tool)
    }

    private func selectTool(_ t: PadTool) {
        switch t {
        case .draw(let tool):
            editor.tool = tool
            editor.stampActive = false
            state.setEyedropper(false)
        case .eyedropper:
            // もう一度押すと、拾わずに直前のツールへ戻る
            state.setEyedropper(!state.eyedropperActive)
        }
    }

    private func toolButton(_ tool: PadTool) -> some View {
        let on = currentTool == tool && !editor.stampActive
        return Button { selectTool(tool) } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(tool.displayName)
    }

    private func barButton(_ symbol: String, selected: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .disabled(disabled)
    }
}

// MARK: - ペンの太さ

/// ツールバーの太さのボタン。今の太さを丸の大きさと数字で見せ、押すと太さの見本の一覧を出す
struct PenSizeButton: View {
    @Bindable var editor: Editor
    @State private var open = false
    @Environment(\.isEnabled) private var isEnabled

    /// 見本の丸の直径（太さ 1〜63 を 4pt〜max に）
    static func dotSize(_ size: Int, max: CGFloat = 20) -> CGFloat {
        let t = sqrt(CGFloat(size - 1) / CGFloat((Editor.penSizes.last ?? 63) - 1))
        return 4 + (max - 4) * t
    }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(uiColor: .label))
                    .frame(width: Self.dotSize(editor.penSize, max: 16), height: Self.dotSize(editor.penSize, max: 16))
                    .frame(width: 16, height: 16)
                Text(verbatim: "\(editor.penSize) px")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(Color.secondary.opacity(isEnabled ? 0.12 : 0.06), in: Capsule())
            .frame(height: 40)
        }
        .accessibilityLabel("ペンと消しゴムの太さ")
        .accessibilityValue(Text(verbatim: "\(editor.penSize) px"))
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 0) {
                Text("ペンと消しゴムの太さ")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Editor.penSizes, id: \.self) { size in row(size) }
                    }
                }
            }
            .frame(width: 200)
            .frame(maxHeight: 480)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func row(_ size: Int) -> some View {
        Button {
            editor.penSize = size
            open = false
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(uiColor: .label))
                    .frame(width: Self.dotSize(size, max: 26), height: Self.dotSize(size, max: 24))
                    .frame(width: 28, height: 28)
                Text(verbatim: "\(size) px")
                    .font(.body.monospacedDigit())
                Spacer()
                if size == editor.penSize {
                    Image(systemName: "checkmark").font(.body.weight(.semibold))
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(size == editor.penSize ? Color.accentColor.opacity(0.15) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ストックの下のバー

struct StockBar: View {
    let state: PadState
    @Bindable var editor: Editor

    var body: some View {
        // 狭い幅（Split View など）では倍率の表示を外してボタンを収める
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                title
                zoomLabel
                Spacer(minLength: 0)
                buttons
            }
            HStack(spacing: 6) {
                title
                Spacer(minLength: 0)
                buttons
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.bar)
    }

    private var title: some View { Text("ストック").font(.caption.bold()) }

    private var zoomLabel: some View {
        Text("\(Int((state.stockZoom * 100).rounded()))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var buttons: some View {
        // 長押し・ダブルタップに気づかなくても使えるように、マーク範囲のコピーとマーク位置への貼り付けを置く
        Button { state.copyMark() } label: { Image(systemName: "doc.on.doc").frame(width: 32, height: 28) }
            .accessibilityLabel("マーク範囲をコピー")
        Button { state.pasteAtMark() } label: { Image(systemName: "doc.on.clipboard").frame(width: 32, height: 28) }
            .accessibilityLabel("マーク位置に貼り付け")
        Divider().frame(height: 18)
        Button { state.stockView?.stepZoom(-1) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 32, height: 28) }
            .accessibilityLabel("縮小")
        Button { state.stockView?.stepZoom(1) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 32, height: 28) }
            .accessibilityLabel("拡大")
        Button { state.stockView?.fitToView() } label: { Image(systemName: "arrow.left.and.right.square").frame(width: 32, height: 28) }
            .accessibilityLabel("シートの幅に合わせる")
        Toggle(isOn: $editor.meta.showCellGrid) { Image(systemName: "grid") }
            .toggleStyle(.button)
            .accessibilityLabel("セルの格子を表示")
    }
}

// MARK: - 設定

struct SettingsPanel: View {
    let state: PadState
    @Bindable var editor: Editor
    @State private var sheetWidth = 0
    @State private var sheetHeight = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("セルの大きさ") {
                    IntRow("幅", value: $editor.meta.cellWidth, min: 1)
                    IntRow("高さ", value: $editor.meta.cellHeight, min: 1)
                    Toggle("セルの格子を表示", isOn: $editor.meta.showCellGrid)
                }
                Section("マーク") {
                    Picker("スナップ", selection: $editor.meta.snap) {
                        ForEach(Snap.choices, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("ルーペの大きさ") {
                    IntRow("幅", value: Binding(get: { editor.meta.lupeWidth }, set: { editor.setLupe(width: $0, height: editor.meta.lupeHeight) }), min: 1)
                    IntRow("高さ", value: Binding(get: { editor.meta.lupeHeight }, set: { editor.setLupe(width: editor.meta.lupeWidth, height: $0) }), min: 1)
                    Button("ルーペをセルの大きさに") {
                        editor.setLupe(width: editor.meta.cellWidth, height: editor.meta.cellHeight)
                        state.requestDisplay()
                    }
                }
                Section {
                    IntRow("幅", value: $sheetWidth, min: 1, step: 16)
                    IntRow("高さ", value: $sheetHeight, min: 1, step: 16)
                    Button("シートの大きさを変える") {
                        editor.resizeSheet(width: min(max(sheetWidth, 1), 8192), height: min(max(sheetHeight, 1), 8192))
                        state.stockView?.fitToView()
                        state.requestDisplay()
                    }
                    .disabled(sheetWidth == editor.image.width && sheetHeight == editor.image.height)
                } header: {
                    Text("シートの大きさ")
                } footer: {
                    Text("左上を基準に大きさを変えます。")
                }
                Section {
                    Toggle("指で描く", isOn: Binding(get: { state.fingerDrawing }, set: { state.setFingerDrawing($0) }))
                    IntRow("長押しで範囲コピーにする移動", value: Binding(get: { state.dragThreshold }, set: { state.dragThreshold = $0 }),
                           min: 1, max: 8, unit: state.dragThreshold == 1 ? Text("ドット（単位・1 のとき）") : Text("ドット（単位）"))
                } header: {
                    Text("入力")
                } footer: {
                    Text("Apple Pencil で描きます。指は 1 本・2 本のドラッグでマーク位置を動かし、ピンチでルーペの大きさを変えます。長押しでスポイト、長押しのままドラッグで範囲をコピーしてスタンプ。ツールバーのスポイトを選ぶと、メインかストックで触れた所の色を拾い、元のツールに戻ります。2 本指タップで取り消し、3 本指タップでやり直し。「指で描く」をオンにすると、マーク位置を動かすのは 2 本指になります。「指で描く」は、切り替えるまでは iPadOS の「Apple Pencil でのみ描画」の設定に合わせます。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(minHeight: 560)
        .onAppear {
            sheetWidth = editor.image.width
            sheetHeight = editor.image.height
        }
    }
}

// MARK: - 新規

struct NewDocumentSheet: View {
    var onCreate: (Int, Int, Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var width = 256
    @State private var height = 256
    @State private var cellWidth = 32
    @State private var cellHeight = 32

    var body: some View {
        NavigationStack {
            Form {
                Section("シートの大きさ（px）") {
                    IntRow("幅", value: $width, min: 1, step: 16)
                    IntRow("高さ", value: $height, min: 1, step: 16)
                }
                Section("セルの大きさ（px）") {
                    IntRow("幅", value: $cellWidth, min: 1)
                    IntRow("高さ", value: $cellHeight, min: 1)
                    HStack {
                        ForEach([(16, 16), (24, 32), (32, 32), (48, 48)], id: \.0) { w, h in
                            Button(w == h ? "\(w)" : "\(w)×\(h)") {
                                cellWidth = w
                                cellHeight = h
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("新規シート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成") {
                        onCreate(min(max(width, 1), 8192), min(max(height, 1), 8192), max(1, cellWidth), max(1, cellHeight))
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - キーボード（Magic Keyboard。Mac 版と同じキー）

struct KeyboardShortcuts: View {
    let state: PadState
    @Bindable var editor: Editor
    let actions: Actions

    struct Actions {
        var new: () -> Void
        var open: () -> Void
        var save: () -> Void
        var saveAs: () -> Void
        var showAnim: () -> Void
        var toggleMap: () -> Void
    }

    var body: some View {
        ZStack {
            key("n", .command, actions.new)
            key("o", .command, actions.open)
            key("s", .command, actions.save)
            key("s", [.command, .shift], actions.saveAs)
            key("z", .command) { state.undo() }
            key("z", [.command, .shift]) { state.redo() }
            key("c", .command) { state.copyMark() }
            // マップを出している間は、見えていないシートを書き換えるキーを受けない
            key("x", .command) { state.cutMark() }
                .disabled(state.mapMode)
            key("v", .command) { state.pasteToStamp() }
                .disabled(state.mapMode)
            key("'", .command) { editor.meta.showCellGrid.toggle() }
            key("0", .command) { state.stockView?.fitToView() }
            key("a", [.command, .shift], actions.showAnim)
            key("m", [.command, .shift], actions.toggleMap)
            key("b", [], { tool(.pen) })
            key("p", [], { tool(.pen) })
            key("e", [], { tool(.eraser) })
            key("g", [], { tool(.fill) })
            key("l", [], { tool(.line) })
            key("r", [], { tool(.rect) })
            key("o", [], { tool(.ellipse) })
            key("m", [], { tool(.select) })
            key("i", []) { state.setEyedropper(!state.eyedropperActive) }
                .disabled(state.mapMode)
            key(.escape, []) {
                state.mainView?.cancelInteraction()
                state.mapView?.cancelInteraction()
                state.setEyedropper(false)
            }
            // 浮かせている間だけ受ける（ほかのときは文字入力などの Return を横取りしない）
            key(.return, []) {
                editor.commitSelection()
                state.requestDisplay()
            }
            .disabled(!editor.isFloating)
            key(.delete, []) { editor.apply(.clear) }
                .disabled(state.mapMode)
            key(.delete, .option) { editor.apply(.fill) }
                .disabled(state.mapMode)
            key(.leftArrow, []) { state.arrowKey(dx: -1, dy: 0, shift: false) }
            key(.rightArrow, []) { state.arrowKey(dx: 1, dy: 0, shift: false) }
            key(.upArrow, []) { state.arrowKey(dx: 0, dy: -1, shift: false) }
            key(.downArrow, []) { state.arrowKey(dx: 0, dy: 1, shift: false) }
            key(.leftArrow, .shift) { state.arrowKey(dx: -1, dy: 0, shift: true) }
            key(.rightArrow, .shift) { state.arrowKey(dx: 1, dy: 0, shift: true) }
            key(.upArrow, .shift) { state.arrowKey(dx: 0, dy: -1, shift: true) }
            key(.downArrow, .shift) { state.arrowKey(dx: 0, dy: 1, shift: true) }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func tool(_ t: Tool) {
        // マップを出している間は、ペン・消しゴム・塗りつぶしのキーがマップのツールになる（ほかの描くツールのキーは何もしない）
        if state.mapMode {
            switch t {
            case .pen: state.mapSession.tool = .pen
            case .eraser: state.mapSession.tool = .eraser
            case .fill: state.mapSession.tool = .fill
            default: break
            }
            return
        }
        editor.tool = t
        editor.stampActive = false
        state.setEyedropper(false)
    }

    private func key(_ k: KeyEquivalent, _ m: EventModifiers, _ action: @escaping () -> Void) -> some View {
        Button("", action: action).keyboardShortcut(k, modifiers: m)
    }
}
