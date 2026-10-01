import AppKit
import NanodotCore
import SwiftUI

struct ContentView: View {
    let state: AppState
    @Bindable var editor: Editor
    @Environment(\.openWindow) private var openWindow

    init(state: AppState) {
        self.state = state
        self.editor = state.editor
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolBarView(state: state, editor: editor)
            Divider()
            // 左右: メイン | ストック＋パレット。初期状態は右を最小幅にしてメインを最大に
            SplitView(horizontal: true, autosaveName: "nanodot.main", firstMin: 320, secondMin: 470, secondMax: 900, secondInitial: 470) {
                MainCanvasRepresentable(state: state)
            } second: {
                // 上下: ストック | カラーピッカー・パレット
                SplitView(horizontal: false, autosaveName: "nanodot.right", firstMin: 160, secondMin: 150, secondMax: 360, secondInitial: 160) {
                    VStack(spacing: 0) {
                        StockRepresentable(state: state)
                        Divider()
                        ZoomControls(state: state, editor: editor)
                    }
                } second: {
                    // カラーピッカーは固定、パレット側だけがスクロールする
                    PalettePanel(state: state, editor: editor)
                }
            }
            Divider()
            StatusBar(state: state, editor: editor)
        }
        .navigationTitle(state.title)
        .onAppear {
            // 前回開いていたらアニメウィンドウも開く
            if UserDefaults.standard.bool(forKey: AnimWindow.openKey) { openWindow(id: "anim") }
            if UserDefaults.standard.bool(forKey: MapWindow.openKey) { openWindow(id: "map") }
        }
        .dropDestination(for: URL.self) { urls, _ in state.openDropped(urls) }
        .sheet(isPresented: Binding(get: { state.showNewDocumentSheet }, set: { state.showNewDocumentSheet = $0 })) {
            NewDocumentSheet(state: state)
        }
    }
}

// MARK: - ツールバー

struct ToolBarView: View {
    let state: AppState
    @Bindable var editor: Editor
    @State private var showSettings = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Tool.allCases, id: \.self) { t in
                    Button {
                        editor.tool = t
                        editor.stampActive = false
                    } label: {
                        Image(systemName: t.symbol)
                            .frame(width: 26, height: 22)
                            .background(editor.tool == t && !editor.stampActive ? Color.accentColor.opacity(0.3) : .clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                    .help(t.displayName)
                }
                Toggle(isOn: $editor.shapeFilled) { Image(systemName: "square.fill") }
                    .toggleStyle(.button)
                    .help("矩形・楕円を塗りつぶす")
                    .disabled(editor.tool != .rect && editor.tool != .ellipse)
            }

            if editor.tool == .text {
                TextToolOptions(settings: $editor.textSettings)
            }

            Divider().frame(height: 20)

            HStack(spacing: 2) {
                opButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "左右反転") { editor.apply(.flipH) }
                opButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "上下反転") { editor.apply(.flipV) }
                opButton("rotate.left", "左に 90° 回転（正方形のとき）") { editor.apply(.rotateCCW) }
                    .disabled(!editor.canRotateMark)
                opButton("rotate.right", "右に 90° 回転（正方形のとき）") { editor.apply(.rotateCW) }
                    .disabled(!editor.canRotateMark)
                opButton("arrow.left", "1 ドット左へシフト") { editor.apply(.shift(-1, 0)) }
                opButton("arrow.right", "1 ドット右へシフト") { editor.apply(.shift(1, 0)) }
                opButton("arrow.up", "1 ドット上へシフト") { editor.apply(.shift(0, -1)) }
                opButton("arrow.down", "1 ドット下へシフト") { editor.apply(.shift(0, 1)) }
                opButton("square.slash", "マーク範囲を消去") { editor.apply(.clear) }
                opButton("square.fill.on.square", "マーク範囲を描画色で塗りつぶし") { editor.apply(.fill) }
            }

            Spacer()

            if editor.stampActive {
                Label("スタンプ（⌥ で透明部分を抜く・Esc / 右クリックで解除）", systemImage: "seal")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }

            Button { openWindow(id: "anim") } label: { Image(systemName: "film") }
                .help("アニメウィンドウ (⇧⌘A)")
            Button { openWindow(id: "map") } label: { Image(systemName: "map") }
                .help("マップウィンドウ (⇧⌘M)")
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .help("シートの設定")
                .popover(isPresented: $showSettings) { SettingsPopover(state: state, editor: editor) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func opButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 22)
        }
        .help(help)
    }
}

struct SettingsPopover: View {
    let state: AppState
    @Bindable var editor: Editor

    var body: some View {
        Form {
            LabeledContent("セルの大きさ") {
                HStack(spacing: 4) {
                    IntField(value: $editor.meta.cellWidth, min: 1)
                    Text("×")
                    IntField(value: $editor.meta.cellHeight, min: 1)
                }
            }
            Toggle("セルの格子を表示", isOn: $editor.meta.showCellGrid)
            LabeledContent("ルーペ（任意）") {
                HStack(spacing: 4) {
                    IntField(value: Binding(get: { editor.meta.lupeWidth }, set: { editor.setLupe(width: $0, height: editor.meta.lupeHeight) }), min: 1)
                    Text("×")
                    IntField(value: Binding(get: { editor.meta.lupeHeight }, set: { editor.setLupe(width: editor.meta.lupeWidth, height: $0) }), min: 1)
                }
            }
            Stepper("右ドラッグの判定: \(state.dragThreshold) ドット",
                    value: Binding(get: { state.dragThreshold }, set: { state.dragThreshold = $0 }), in: 1...8)
            LabeledContent("シート") {
                HStack {
                    Text("\(editor.image.width) × \(editor.image.height)")
                    Button("変更...") { state.showSheetSizeDialog() }
                }
            }
            Divider()
            MCPSettings(state: state)
        }
        .padding()
        .frame(width: 320)
    }
}

// MARK: - ステータスバー

struct StatusBar: View {
    let state: AppState
    @Bindable var editor: Editor

    var body: some View {
        HStack(spacing: 14) {
            if let p = state.cursorDot {
                Text("\(p.x), \(p.y)").frame(width: 70, alignment: .leading)
            } else {
                Text("").frame(width: 70)
            }
            let m = editor.meta
            Text("マーク (\(m.mark.x), \(m.mark.y)) \(m.lupeWidth)×\(m.lupeHeight)")
            Text("セル \(m.cellWidth)×\(m.cellHeight)")
            Text("シート \(editor.image.width)×\(editor.image.height)")
            if let c = editor.clipboard {
                Text("クリップボード \(c.width)×\(c.height)")
            }
            if case .running(let port) = state.mcpStatus {
                Label("MCP :\(port)", systemImage: "antenna.radiowaves.left.and.right")
                    .help("MCP サーバーが \(state.mcpURL) で待ち受け中")
            }
            Spacer()
            Text("右クリック: スポイト／右ドラッグ: コピー→スタンプ")
            Divider().frame(height: 14)
            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!editor.canUndo)
                .help(editor.undoLabel.map { "取り消し: \($0) (⌘Z)" } ?? "取り消し (⌘Z)")
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!editor.canRedo)
                .help(editor.redoLabel.map { "やり直し: \($0) (⇧⌘Z)" } ?? "やり直し (⇧⌘Z)")
        }
        .buttonStyle(.borderless)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}

// MARK: - 新規

struct NewDocumentSheet: View {
    let state: AppState
    @State private var width = 256
    @State private var height = 256
    @State private var cellWidth = 32
    @State private var cellHeight = 32
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新規シート").font(.headline)
            Form {
                LabeledContent("シート") {
                    HStack(spacing: 4) {
                        IntField(value: $width, min: 1)
                        Text("×")
                        IntField(value: $height, min: 1)
                        Text("px")
                    }
                }
                LabeledContent("セル") {
                    HStack(spacing: 4) {
                        IntField(value: $cellWidth, min: 1)
                        Text("×")
                        IntField(value: $cellHeight, min: 1)
                        Text("px")
                    }
                }
                LabeledContent("") {
                    HStack {
                        Button("16") { cellWidth = 16; cellHeight = 16 }
                        Button("24×32") { cellWidth = 24; cellHeight = 32 }
                        Button("32") { cellWidth = 32; cellHeight = 32 }
                        Button("48") { cellWidth = 48; cellHeight = 48 }
                    }
                    .controlSize(.small)
                }
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("作成") {
                    state.newDocument(width: width, height: height, cellWidth: cellWidth, cellHeight: cellHeight)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// テキストツールの設定（文字・フォント・大きさ）
struct TextToolOptions: View {
    @Binding var settings: TextSettings

    var body: some View {
        HStack(spacing: 6) {
            TextField("文字", text: $settings.text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .help("メインをクリックすると、カーソル位置を左上にしてこの文字を描きます")
            Picker("", selection: $settings.fontName) {
                ForEach(TextRenderer.fonts, id: \.name) { f in Text(f.label).tag(f.name) }
            }
            .labelsHidden()
            .fixedSize()
            IntField(value: Binding(get: { Int(settings.size) }, set: { settings.size = Double($0) }), min: 4, max: 128, width: 40)
            Text("pt").font(.caption).foregroundStyle(.secondary)
            Toggle("なめらか", isOn: $settings.antialias)
                .toggleStyle(.checkbox)
                .help("縁をなめらかにする（半透明の画素ができます）")
        }
        .controlSize(.small)
    }
}

/// MCP サーバーの設定（設定のポップオーバー内）
struct MCPSettings: View {
    let state: AppState

    private var statusText: String {
        switch state.mcpStatus {
        case .stopped: return "停止中"
        case .starting: return "起動中…"
        case .running: return "\(state.mcpURL) で待ち受け中"
        case .failed(let m): return "起動できません: \(m)"
        }
    }

    var body: some View {
        Toggle("MCP サーバー", isOn: Binding(get: { state.mcpEnabled }, set: { state.mcpEnabled = $0 }))
            .help("AI エージェントから nanodot を操作できるようにする（このマシンからの接続だけ受け付けます）")
        LabeledContent("ポート") {
            IntField(value: Binding(get: { state.mcpPort }, set: { state.mcpPort = $0 }), min: 1024, max: 65535, width: 64)
        }
        Text(statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        Button("Claude Code に登録するコマンドをコピー") {
            let cmd = "claude mcp add --transport http nanodot \(state.mcpURL)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
        .controlSize(.small)
    }
}
