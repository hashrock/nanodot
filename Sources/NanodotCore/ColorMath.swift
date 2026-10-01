import Foundation

/// HSL（h: 0〜360、s・l: 0〜1）
public struct HSL: Equatable, Sendable {
    public var h: Double
    public var s: Double
    public var l: Double

    public init(h: Double, s: Double, l: Double) {
        self.h = h; self.s = s; self.l = l
    }

    public init(_ c: RGBA) {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        l = (mx + mn) / 2
        let d = mx - mn
        guard d > 0 else {
            h = 0; s = 0
            return
        }
        s = d / (1 - abs(2 * l - 1))
        var hh: Double
        if mx == r { hh = ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if mx == g { hh = (b - r) / d + 2 } else { hh = (r - g) / d + 4 }
        hh *= 60
        if hh < 0 { hh += 360 }
        h = hh
    }

    public func rgba(alpha: UInt8) -> RGBA {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360)) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var (r, g, b): (Double, Double, Double)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, ((v + m) * 255).rounded()))) }
        return RGBA(q(r), q(g), q(b), alpha)
    }
}

/// スロット（色の並び）への操作
public enum SlotOps {
    /// 範囲の両端の色の間を補間して埋める（両端が空なら何もしない）
    public static func gradient(_ slots: [RGBA?], _ a: Int, _ b: Int, hsl: Bool) -> [RGBA?] {
        let lo = min(a, b), hi = max(a, b)
        guard lo >= 0, hi < slots.count, hi - lo >= 2, let ca = slots[lo], let cb = slots[hi] else { return slots }
        var out = slots
        for k in (lo + 1)..<hi {
            let t = Double(k - lo) / Double(hi - lo)
            out[k] = hsl ? lerpHSL(ca, cb, t) : lerpRGB(ca, cb, t)
        }
        return out
    }

    static func lerp(_ a: UInt8, _ b: UInt8, _ t: Double) -> UInt8 {
        UInt8(max(0, min(255, (Double(a) + (Double(b) - Double(a)) * t).rounded())))
    }

    public static func lerpRGB(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        RGBA(lerp(a.r, b.r, t), lerp(a.g, b.g, t), lerp(a.b, b.b, t), lerp(a.a, b.a, t))
    }

    /// 色相は近い方向に回す。無彩色の側はもう一方の色相を使う
    public static func lerpHSL(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        var ha = HSL(a), hb = HSL(b)
        if ha.s < 0.001 { ha.h = hb.h }
        if hb.s < 0.001 { hb.h = ha.h }
        var dh = hb.h - ha.h
        if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        var h = ha.h + dh * t
        h = h.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let c = HSL(h: h, s: ha.s + (hb.s - ha.s) * t, l: ha.l + (hb.l - ha.l) * t)
        return c.rgba(alpha: lerp(a.a, b.a, t))
    }

    public static func reversed(_ slots: [RGBA?], _ a: Int, _ b: Int) -> [RGBA?] {
        let lo = min(a, b), hi = max(a, b)
        guard lo >= 0, hi < slots.count else { return slots }
        var out = slots
        out.replaceSubrange(lo...hi, with: slots[lo...hi].reversed())
        return out
    }

    /// from のスロットを to へ。copy でなければ入れ替え
    public static func move(_ slots: [RGBA?], from: Int, to: Int, copy: Bool) -> [RGBA?] {
        guard from != to, slots.indices.contains(from), slots.indices.contains(to) else { return slots }
        var out = slots
        if copy {
            out[to] = slots[from]
        } else {
            out.swapAt(from, to)
        }
        return out
    }
}
