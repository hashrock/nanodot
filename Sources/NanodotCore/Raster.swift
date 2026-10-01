import Foundation

/// ドット単位の図形ラスタライズ
public enum Raster {
    /// ブレゼンハムの直線（両端を含む）
    public static func line(_ a: IntPoint, _ b: IntPoint) -> [IntPoint] {
        var pts: [IntPoint] = []
        var x = a.x, y = a.y
        let dx = abs(b.x - a.x), dy = -abs(b.y - a.y)
        let sx = a.x < b.x ? 1 : -1, sy = a.y < b.y ? 1 : -1
        var err = dx + dy
        while true {
            pts.append(IntPoint(x, y))
            if x == b.x && y == b.y { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
        return pts
    }

    public static func rect(_ a: IntPoint, _ b: IntPoint, filled: Bool) -> [IntPoint] {
        let r = IntRect(corner: a, b)
        var pts: [IntPoint] = []
        for y in r.y..<r.maxY {
            for x in r.x..<r.maxX where filled || x == r.x || y == r.y || x == r.maxX - 1 || y == r.maxY - 1 {
                pts.append(IntPoint(x, y))
            }
        }
        return pts
    }

    /// 2 点を対角とする矩形に内接する楕円。輪郭は 4 近傍のどれかが外側になる画素（8 連結の細線）
    public static func ellipse(_ a: IntPoint, _ b: IntPoint, filled: Bool) -> [IntPoint] {
        let r = IntRect(corner: a, b)
        let rx = Double(r.width) / 2, ry = Double(r.height) / 2
        let cx = Double(r.x) + rx, cy = Double(r.y) + ry
        func inside(_ x: Int, _ y: Int) -> Bool {
            guard r.contains(IntPoint(x, y)) else { return false }
            let nx = (Double(x) + 0.5 - cx) / rx, ny = (Double(y) + 0.5 - cy) / ry
            return nx * nx + ny * ny <= 1.0
        }
        var pts: [IntPoint] = []
        for y in r.y..<r.maxY {
            for x in r.x..<r.maxX where inside(x, y) {
                if filled || !inside(x - 1, y) || !inside(x + 1, y) || !inside(x, y - 1) || !inside(x, y + 1) {
                    pts.append(IntPoint(x, y))
                }
            }
        }
        return pts
    }

    /// Shift 押下時の制約: 直線は 45° 単位、矩形・楕円は正方形
    public static func constrain(_ a: IntPoint, _ b: IntPoint, diagonalSnap: Bool) -> IntPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        if diagonalSnap {
            let adx = abs(dx), ady = abs(dy)
            if adx > ady * 2 { return IntPoint(b.x, a.y) }
            if ady > adx * 2 { return IntPoint(a.x, b.y) }
        }
        let m = max(abs(dx), abs(dy))
        return IntPoint(a.x + (dx < 0 ? -m : m), a.y + (dy < 0 ? -m : m))
    }

    /// 4 近傍で同じ色がつながる領域（clip 内）
    public static func floodRegion(_ buf: PixelBuffer, from p: IntPoint, clip: IntRect) -> [IntPoint] {
        let area = clip.intersection(buf.bounds)
        guard area.contains(p) else { return [] }
        let target = buf[p.x, p.y]
        var visited = [Bool](repeating: false, count: area.width * area.height)
        var stack = [p]
        var out: [IntPoint] = []
        func idx(_ q: IntPoint) -> Int { (q.y - area.y) * area.width + (q.x - area.x) }
        visited[idx(p)] = true
        while let q = stack.popLast() {
            out.append(q)
            for n in [IntPoint(q.x - 1, q.y), IntPoint(q.x + 1, q.y), IntPoint(q.x, q.y - 1), IntPoint(q.x, q.y + 1)]
            where area.contains(n) && !visited[idx(n)] && buf[n.x, n.y] == target {
                visited[idx(n)] = true
                stack.append(n)
            }
        }
        return out
    }
}
