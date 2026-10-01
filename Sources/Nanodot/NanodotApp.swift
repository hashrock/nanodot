import AppKit
import NanodotCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 終了処理中（ウィンドウが閉じても開閉状態を記録しない）
    static var isTerminating = false
    var state: AppState?
    private var keyMonitor: Any?
    private var closeGuard: WindowCloseGuard?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self else { return e }
            return self.handleKey(e)
        }
        DispatchQueue.main.async { [self] in
            if let state, let window = state.mainView?.window {
                closeGuard = WindowCloseGuard(window: window, state: state)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let state, !state.confirmDiscardChanges() { return .terminateCancel }
        Self.isTerminating = true
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first, let state, state.confirmDiscardChanges() { state.open(url: url) }
    }

    /// 単キーのショートカット（テキスト入力中は無視）
    private func handleKey(_ e: NSEvent) -> NSEvent? {
        // メインウィンドウだけで受け付ける（アニメウィンドウでは普通のキー操作）
        guard let state, e.window != nil, e.window === state.mainView?.window else { return e }
        if let tv = e.window?.firstResponder as? NSTextView, tv.isEditable { return e }
        let editor = state.editor
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if e.keyCode == 49 { // space: 押している間はパン
            if e.type == .keyDown {
                if !e.isARepeat {
                    state.mainView?.setSpaceHeld(true)
                    state.stockView?.setSpaceHeld(true)
                }
            } else {
                state.mainView?.setSpaceHeld(false)
                state.stockView?.setSpaceHeld(false)
            }
            return nil
        }
        if e.type == .keyUp { return e }
        if flags == [.command] {
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "c":
                state.copyMark()
                return nil
            case "v":
                state.pasteToStamp()
                return nil
            default:
                return e
            }
        }
        if flags.contains(.command) || flags.contains(.control) { return e }
        switch e.keyCode {
        case 51, 117: // delete
            editor.apply(flags.contains(.option) ? .fill : .clear)
            return nil
        case 53: // escape
            state.mainView?.cancelInteraction()
            return nil
        case 123: state.moveMark(dx: -1, dy: 0, byLupe: flags.contains(.shift)); return nil
        case 124: state.moveMark(dx: 1, dy: 0, byLupe: flags.contains(.shift)); return nil
        case 125: state.moveMark(dx: 0, dy: 1, byLupe: flags.contains(.shift)); return nil
        case 126: state.moveMark(dx: 0, dy: -1, byLupe: flags.contains(.shift)); return nil
        default: break
        }
        let tool: Tool
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "b", "p": tool = .pen
        case "e": tool = .eraser
        case "g": tool = .fill
        case "l": tool = .line
        case "r": tool = .rect
        case "o": tool = .ellipse
        default: return e
        }
        editor.tool = tool
        editor.stampActive = false
        state.requestDisplay()
        return nil
    }
}

/// 未保存のままウィンドウを閉じようとしたら、ウィンドウを残したまま終了確認を出す。
/// SwiftUI が設定したウィンドウの delegate に割り込み、それ以外のメッセージは元の delegate に転送する
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    private weak var original: NSWindowDelegate?
    private let state: AppState

    init(window: NSWindow, state: AppState) {
        self.window = window
        self.original = window.delegate
        self.state = state
        super.init()
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // メインウィンドウを閉じたらアプリを終了する（アニメウィンドウが開いていても）。
        // 未保存の確認は applicationShouldTerminate に任せる
        NSApp.terminate(nil)
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
    }
}

@main
struct NanodotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("Nanodot", id: "main") {
            ContentView(state: state)
                .onAppear { delegate.state = state }
        }
        .defaultSize(width: 1280, height: 860)
        .commands { AppCommands(state: state) }

        Window("アニメ", id: "anim") {
            AnimWindow(state: state)
        }
        .defaultSize(width: 420, height: 640)
        .animWindowRestorationDisabled()

        Window("マップ", id: "map") {
            MapWindow(state: state, editor: state.editor)
        }
        .defaultSize(width: 900, height: 640)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .animWindowRestorationDisabled()
        .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}

struct AppCommands: Commands {
    let state: AppState
    var editor: Editor { state.editor }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新規...") {
                if state.confirmDiscardChanges() { state.showNewDocumentSheet = true }
            }
            .keyboardShortcut("n")
            Button("開く...") { state.open() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存") { state.save() }
                .keyboardShortcut("s")
            Button("別名で保存...") { state.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Menu("アニメを書き出し") {
                ForEach(AnimExport.Format.allCases, id: \.self) { f in
                    Button(f.label + "...") { state.exportAnim(f, scale: 1) }
                }
            }
            .disabled(state.selectedAnimID == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            // マップウィンドウが前面ならマップの取り消し・やり直し
            Button(editor.undoLabel.map { "取り消し: \($0)" } ?? "取り消し") {
                if state.isMapWindowKey { state.mapUndo() } else { editor.undo() }
            }
            .keyboardShortcut("z")
            .disabled(!editor.canUndo && !state.canMapUndo)
            Button(editor.redoLabel.map { "やり直し: \($0)" } ?? "やり直し") {
                if state.isMapWindowKey { state.mapRedo() } else { editor.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!editor.canRedo && !state.canMapRedo)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("マーク範囲をコピー (⌘C)") { state.copyMark() }
            Button("スタンプ (⌘V)") { state.pasteToStamp() }
                .disabled(editor.clipboard == nil && !NSPasteboard.general.canReadItem(withDataConformingToTypes: ["public.png", "public.tiff"]))
        }
        CommandMenu("マーク") {
            Picker("スナップ", selection: Binding(get: { editor.meta.snap }, set: { editor.meta.snap = $0 })) {
                ForEach(Snap.choices, id: \.self) { s in Text(s.label).tag(s) }
            }
            Button("ルーペをセルの大きさに") { editor.setLupe(width: editor.meta.cellWidth, height: editor.meta.cellHeight) }
            Divider()
            Button("左右反転") { editor.apply(.flipH) }
            Button("上下反転") { editor.apply(.flipV) }
            Button("左に 90° 回転") { editor.apply(.rotateCCW) }
                .disabled(!editor.canRotateMark)
            Button("右に 90° 回転") { editor.apply(.rotateCW) }
                .disabled(!editor.canRotateMark)
            Divider()
            Button("消去 (Delete)") { editor.apply(.clear) }
            Button("描画色で塗りつぶし (⌥Delete)") { editor.apply(.fill) }
            Divider()
            Button("シートサイズ...") { state.showSheetSizeDialog() }
        }
        CommandGroup(before: .toolbar) {
            Button(editor.meta.showCellGrid ? "セルの格子を隠す" : "セルの格子を表示") {
                editor.meta.showCellGrid.toggle()
            }
            .keyboardShortcut("'")
            Button("ストックを全体表示") { state.stockView?.fitToView() }
                .keyboardShortcut("0")
            Divider()
        }
    }
}

extension Scene {
    /// アニメウィンドウの開閉はアプリで記憶するので、システムの復元はしない
    func animWindowRestorationDisabled() -> some Scene {
        if #available(macOS 15.0, *) {
            return restorationBehavior(.disabled)
        } else {
            return self
        }
    }
}
