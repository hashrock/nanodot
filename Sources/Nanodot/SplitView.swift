import AppKit
import SwiftUI

/// NSSplitViewController で 2 つのペインを分ける。分割位置は autosaveName で macOS が保存・復元する
struct SplitView<First: View, Second: View>: NSViewControllerRepresentable {
    /// true なら左右、false なら上下に分ける
    var horizontal: Bool
    var autosaveName: String
    var firstMin: CGFloat
    var secondMin: CGFloat
    var secondMax: CGFloat = 10_000
    /// 保存された位置がないときの second の大きさ
    var secondInitial: CGFloat
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    func makeNSViewController(context: Context) -> SplitController<First, Second> {
        SplitController(self)
    }

    func updateNSViewController(_ c: SplitController<First, Second>, context: Context) {
        c.firstHost.rootView = first
        c.secondHost.rootView = second
    }
}

final class SplitController<First: View, Second: View>: NSSplitViewController {
    let firstHost: NSHostingController<First>
    let secondHost: NSHostingController<Second>
    private let config: SplitView<First, Second>
    private var didApplyInitial = false

    init(_ config: SplitView<First, Second>) {
        self.config = config
        firstHost = NSHostingController(rootView: config.first)
        secondHost = NSHostingController(rootView: config.second)
        // SwiftUI の理想サイズでウィンドウを広げさせない（大きさは分割ビューが決める）
        firstHost.sizingOptions = []
        secondHost.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = config.horizontal
        splitView.dividerStyle = .thin
        let a = NSSplitViewItem(viewController: firstHost)
        let b = NSSplitViewItem(viewController: secondHost)
        a.minimumThickness = config.firstMin
        b.minimumThickness = config.secondMin
        b.maximumThickness = config.secondMax
        // ウィンドウの大きさを変えたときは first が伸び縮みする
        a.holdingPriority = NSLayoutConstraint.Priority(250)
        b.holdingPriority = NSLayoutConstraint.Priority(260)
        addSplitViewItem(a)
        addSplitViewItem(b)
        splitView.autosaveName = config.autosaveName
    }

    private var hasSavedPosition: Bool {
        UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(config.autosaveName)") != nil
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 保存された位置がなければ、初回だけ second を決めた大きさにする
        guard !didApplyInitial else { return }
        let total = config.horizontal ? splitView.bounds.width : splitView.bounds.height
        guard total > 0 else { return }
        didApplyInitial = true
        guard !hasSavedPosition else { return }
        let pos = total - config.secondInitial - splitView.dividerThickness
        splitView.setPosition(max(config.firstMin, pos), ofDividerAt: 0)
    }
}
