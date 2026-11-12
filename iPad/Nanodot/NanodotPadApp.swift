import SwiftUI

@main
struct NanodotPadApp: App {
    @State private var state = PadState()

    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(simulator)
            if let panel = SimulatorHooks.panel {
                SimulatorPanelPreview(state: state, panel: panel)
            } else if let size = SimulatorHooks.layoutSize {
                // 検証用: 横向き・Split View の幅を、画面の左上に切り詰めて再現する
                PadContentView(state: state)
                    .frame(width: size.width, height: size.height)
                    .border(Color.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                PadContentView(state: state)
            }
            #else
            PadContentView(state: state)
            #endif
        }
    }
}
