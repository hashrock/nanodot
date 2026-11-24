import NanodotCore
import SwiftUI

/// マップのパネル（Mac 版のマップウィンドウのツールバー・レイヤー一覧・ステータスにあたる）
struct MapPanel: View {
    let state: PadState
    @Bindable var editor: Editor
    @Bindable var session: MapSession
    @State private var width = 20
    @State private var height = 15
    @State private var confirmRemove = false
    @State private var renaming: Int?
    @State private var draftName = ""

    init(state: PadState, editor: Editor) {
        self.state = state
        self.editor = editor
        session = state.mapSession
    }

    var body: some View {
        if state.isOutsideDocument {
            OutsideNotice(state: state, feature: L("マップ"))
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("マップ", selection: Binding(get: { session.selectedMapID }, set: { session.select($0) })) {
                    if editor.meta.maps.isEmpty { Text("なし").tag(UUID?.none) }
                    ForEach(editor.meta.maps) { m in Text(m.name.isEmpty ? L("（無題）") : m.name).tag(UUID?.some(m.id)) }
                }
                .labelsHidden()
                Spacer()
                Button { session.addMap() } label: { Image(systemName: "plus").frame(width: 32, height: 32) }
                    .accessibilityLabel("マップを追加")
                Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash").frame(width: 32, height: 32) }
                    .disabled(session.index == nil)
                    .accessibilityLabel("マップを削除")
            }
            .confirmationDialog("マップを削除しますか？", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("削除", role: .destructive) { session.removeMap() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("マップの削除は取り消せません。")
            }

            if let m = session.map {
                PanelGroup {
                    TextField("名前", text: Binding(get: { m.name }, set: { session.renameMap($0) }))
                        .frame(minHeight: 44)
                    Divider()
                    IntRow("幅", value: $width, min: 1, max: 512)
                    Divider()
                    IntRow("高さ", value: $height, min: 1, max: 512)
                    Divider()
                    Button { session.resize(width: width, height: height) } label: {
                        PanelButtonLabel("大きさを変える", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(width == m.width && height == m.height)
                }
                .onAppear { width = m.width; height = m.height }
                .onChange(of: m.id) { _, _ in width = m.width; height = m.height }
                .onChange(of: m.width) { _, v in width = v }
                .onChange(of: m.height) { _, v in height = v }

                layers(m)

                PanelGroup {
                    Toggle("通行不可のタイルに × を表示", isOn: Binding(get: { state.showAnnotations }, set: { state.showAnnotations = $0 }))
                        .frame(minHeight: 44)
                }

                brushInfo
            } else {
                Text("＋ でマップを作ります。ストックで選んだセルをタイルとして置きます")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .alert(Text("レイヤーの名前"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名前", text: $draftName)
            Button("キャンセル", role: .cancel) { renaming = nil }
            Button("OK") {
                if let i = renaming { session.renameLayer(i, draftName) }
                renaming = nil
            }
        }
    }

    private func layers(_ m: TileMapDef) -> some View {
        PanelGroup("レイヤー") {
            // 上のレイヤーを上に表示
            ForEach(Array(m.layers.indices.reversed()), id: \.self) { i in
                if i != m.layers.count - 1 { Divider() }
                HStack(spacing: 10) {
                    Button { session.toggleLayerVisible(i) } label: {
                        Image(systemName: m.layers[i].visible ? "eye" : "eye.slash")
                            .foregroundStyle(m.layers[i].visible ? .primary : .tertiary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(m.layers[i].visible ? L("隠す") : L("表示する"))
                    Text(m.layers[i].name)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if session.layer == i {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .onTapGesture { session.layer = i }
                .contextMenu {
                    Button { beginRename(i, m) } label: { Label("名前を変更", systemImage: "pencil") }
                }
                .background(session.layer == i ? Color.accentColor.opacity(0.15) : .clear)
                .accessibilityAddTraits(session.layer == i ? .isSelected : [])
            }
            Divider()
            HStack(spacing: 4) {
                Button { session.addLayer() } label: { Image(systemName: "plus").frame(width: 36, height: 36) }
                    .accessibilityLabel("レイヤーを追加")
                Button { session.removeLayer() } label: { Image(systemName: "minus").frame(width: 36, height: 36) }
                    .disabled(m.layers.count <= 1)
                    .accessibilityLabel("レイヤーを削除")
                Button { beginRename(session.layer, m) } label: { Image(systemName: "pencil").frame(width: 36, height: 36) }
                    .accessibilityLabel("名前を変更")
                Spacer()
                Button { session.moveLayer(1) } label: { Image(systemName: "chevron.up").frame(width: 36, height: 36) }
                    .disabled(session.layer >= m.layers.count - 1)
                    .accessibilityLabel("上へ")
                Button { session.moveLayer(-1) } label: { Image(systemName: "chevron.down").frame(width: 36, height: 36) }
                    .disabled(session.layer <= 0)
                    .accessibilityLabel("下へ")
            }
            .buttonStyle(.borderless)
        }
    }

    private func beginRename(_ i: Int, _ m: TileMapDef) {
        guard m.layers.indices.contains(i) else { return }
        draftName = m.layers[i].name
        renaming = i
    }

    private var brushInfo: some View {
        let b = session.brush
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.brushOverride == nil ? L("ブラシ \(b.width)×\(b.height)（マーク範囲）") : L("ブラシ \(b.width)×\(b.height)（マップから拾った）"))
                Spacer()
                if session.brushOverride != nil {
                    Button("マーク範囲に戻す") { session.brushOverride = nil }
                        .font(.caption)
                }
            }
            Text("タイル \(editor.meta.cellWidth)×\(editor.meta.cellHeight)")
            Text("ストックでセルを選んで、Apple Pencil で置きます。長押しでタイルを拾い、長押しのままドラッグで範囲を拾います。指でスクロール、ピンチで拡大縮小。")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// ツールバーに出すマップのツール
extension MapTool {
    var displayName: String {
        switch self {
        case .pen: return L("ペン (B)")
        case .eraser: return L("消しゴム (E)")
        case .fill: return L("塗りつぶし (G)")
        }
    }
}
