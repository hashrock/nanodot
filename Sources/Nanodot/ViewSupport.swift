import AppKit
import NanodotCore
import SwiftUI

extension RGBA {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func q(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(q(ns.redComponent), q(ns.greenComponent), q(ns.blueComponent), q(ns.alphaComponent))
    }
}
