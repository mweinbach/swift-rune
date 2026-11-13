import Foundation
import Rune

enum HoverConstants {
    static let edgeSlop: Float = 8.0
    static let edgeHits = 16
    static let allEdgeHits = 1200
}

struct HoverTrace {
    let ends: (Int, Int)
    let part: Part?
    var ops: [CanvasOp]
    let line: [Vec2]
    let label: (index: Int, rect: (Float, Float, Float, Float))?
}

struct HoverSpot {
    let key: String
    let rect: (Float, Float, Float, Float)
    let shapes: [Shape]
    let labels: [Int]
}

extension Canvas {
    mutating func region(_ i: Int, outline: [Vec2]) {
        guard let (mode, _) = hover, mode != .off else { return }
        if regions.count <= i {
            regions.append(contentsOf: repeatElement([], count: i + 1 - regions.count))
        }
        regions[i] = outline
    }

    mutating func trace(
        from: Int,
        to: Int,
        start: Int,
        line: Color,
        label: (index: Int, rect: (Float, Float, Float, Float), back: Color)?
    ) {
        guard let (mode, lit) = hover, mode != .off else { return }
        var path: [Vec2] = []
        var traceOps: [CanvasOp] = []
        for op in ops[start...] {
            switch op {
            case let .fill(p, c) where c == line:
                traceOps.append(.fill(points: p, color: lit))
            case let .stroke(points, closed, width, roundCap, color) where color == line:
                if !closed {
                    path.append(contentsOf: points)
                }
                traceOps.append(.stroke(points: points, closed: closed, width: width + 0.5, roundCap: roundCap, color: lit))
            default:
                traceOps.append(op)
            }
        }
        if let (_, g, back) = label {
            let pill = CanvasMath.roundedRect(x0: g.0, y0: g.1, x1: g.2, y1: g.3, r: 4.0)
            traceOps.append(.fill(points: pill, color: back))
            traceOps.append(.fill(points: pill, color: lit.alpha(lit.a * 0.14)))
            traceOps.append(.stroke(points: pill, closed: true, width: 1.0, roundCap: true, color: lit))
        }
        let part = currentPart()
        traces.append(HoverTrace(
            ends: (from, to),
            part: part,
            ops: traceOps,
            line: path,
            label: label.map { ($0.index, $0.rect) }
        ))
    }

    func hovers(map: (Vec2) -> Vec2) -> [HoverSpot] {
        guard let (reach, lit) = hover, reach != .off else { return [] }
        func drawn(_ v: Int) -> Bool {
            v < regions.count && regions[v].count >= 3
        }
        func makeRect(_ lo: Vec2, _ hi: Vec2) -> (Float, Float, Float, Float) {
            let a = map(lo)
            let z = map(hi)
            return (a.x, a.y, z.x - a.x, z.y - a.y)
        }
        let boxes: [(Float, Float, Float, Float)] = (0..<regions.count)
            .filter { drawn($0) }
            .map { v in
                let (lo, hi) = HoverGeometry.bounds(of: regions[v])
                return makeRect(lo, hi)
            }
        func outlineOp(_ v: Int) -> CanvasOp {
            .stroke(points: regions[v], closed: true, width: 1.0, roundCap: true, color: lit)
        }

        var spots: [HoverSpot] = []
        var seen: [String: Int] = [:]
        func makeKey(_ part: Part) -> String {
            let base = "hover:\(partKey(part).0)"
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            return n == 1 ? base : "\(base)~\(n - 1)"
        }

        var budget = HoverConstants.allEdgeHits
        for (k, t) in traces.enumerated() {
            let edgeKey = makeKey(t.part ?? .index(.edge, k))
            let shapes = t.ops.map { $0.mapped(by: map).toShape() }
            let labels = t.label.map { [$0.index] } ?? []
            let linePts = t.line.map(map)
            var hits = HoverGeometry.cutAway(HoverGeometry.lineHits(line: linePts, slop: HoverConstants.edgeSlop), nodes: boxes)
            if hits.count > budget {
                hits = Array(hits.prefix(budget))
            }
            budget -= hits.count
            for (j, r) in hits.enumerated() {
                spots.append(HoverSpot(key: "\(edgeKey).\(j)", rect: r, shapes: shapes, labels: labels))
            }
            if let (_, g) = t.label {
                spots.append(HoverSpot(key: "\(edgeKey).t", rect: makeRect(Vec2(g.0, g.1), Vec2(g.2, g.3)), shapes: shapes, labels: labels))
            }
        }

        for v in (0..<regions.count).filter({ drawn($0) }) {
            let mine = traces.filter { $0.ends.0 == v || $0.ends.1 == v }
            if mine.isEmpty { continue }
            var shapes = mine.flatMap { $0.ops }.map { $0.mapped(by: map).toShape() }
            if reach == .neighbours {
                var near = mine.flatMap { [$0.ends.0, $0.ends.1] }.filter { drawn($0) }
                near = Array(Set(near)).sorted()
                for u in near {
                    shapes.append(outlineOp(u).mapped(by: map).toShape())
                }
            }
            let (lo, hi) = HoverGeometry.bounds(of: regions[v])
            let labels = mine.compactMap { $0.label?.index }
            spots.append(HoverSpot(key: makeKey(.index(.node, v)), rect: makeRect(lo, hi), shapes: shapes, labels: labels))
        }
        return spots
    }
}

enum HoverGeometry {
    static func bounds(of pts: [Vec2]) -> (Vec2, Vec2) {
        var lo = Vec2(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var hi = Vec2(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for p in pts {
            lo = Vec2(min(lo.x, p.x), min(lo.y, p.y))
            hi = Vec2(max(hi.x, p.x), max(hi.y, p.y))
        }
        return (lo, hi)
    }

    static func lineHits(line: [Vec2], slop: Float) -> [(Float, Float, Float, Float)] {
        var pts: [Vec2] = []
        if line.count >= 2 {
            for i in 0..<(line.count - 1) {
                let a = line[i]
                let b = line[i + 1]
                let n = Int(min(max(ceilf(CanvasMath.dist(a, b) / 4.0), 1.0), 200.0))
                for step in 0..<n {
                    pts.append(CanvasMath.lerp(a, b, Float(step) / Float(n)))
                }
            }
        }
        if let last = line.last {
            pts.append(last)
        }
        pts = pts.filter { $0.x.isFinite && $0.y.isFinite }
        guard !pts.isEmpty else { return [] }

        var thin = slop
        while true {
            var out: [(Float, Float, Float, Float)] = []
            var lo = pts[0]
            var hi = pts[0]
            if pts.count >= 2 {
                for i in 0..<(pts.count - 1) {
                    let prev = pts[i]
                    let p = pts[i + 1]
                    let nlo = Vec2(min(lo.x, p.x), min(lo.y, p.y))
                    let nhi = Vec2(max(hi.x, p.x), max(hi.y, p.y))
                    if min(nhi.x - nlo.x, nhi.y - nlo.y) > thin {
                        out.append((lo.x - slop, lo.y - slop, hi.x - lo.x + 2.0 * slop, hi.y - lo.y + 2.0 * slop))
                        lo = Vec2(min(prev.x, p.x), min(prev.y, p.y))
                        hi = Vec2(max(prev.x, p.x), max(prev.y, p.y))
                    } else {
                        lo = nlo
                        hi = nhi
                    }
                }
            }
            out.append((lo.x - slop, lo.y - slop, hi.x - lo.x + 2.0 * slop, hi.y - lo.y + 2.0 * slop))
            if out.count <= HoverConstants.edgeHits || thin > 4096.0 {
                return out
            }
            thin *= 2.0
        }
    }

    static func cutAway(
        _ hits: [(Float, Float, Float, Float)],
        nodes: [(Float, Float, Float, Float)]
    ) -> [(Float, Float, Float, Float)] {
        hits.compactMap { rect in
            var r = rect
            for n in nodes {
                let x0 = r.0, y0 = r.1, x1 = r.0 + r.2, y1 = r.1 + r.3
                let nx0 = n.0, ny0 = n.1, nx1 = n.0 + n.2, ny1 = n.1 + n.3
                if nx0 >= x1 || nx1 <= x0 || ny0 >= y1 || ny1 <= y0 {
                    continue
                }
                let sides: [(Float, Float, Float, Float)] = [
                    (x0, y0, nx0 - x0, r.3),
                    (nx1, y0, x1 - nx1, r.3),
                    (x0, y0, r.2, ny0 - y0),
                    (x0, ny1, r.2, y1 - ny1),
                ]
                guard let best = sides
                    .filter({ $0.2 >= 4.0 && $0.3 >= 4.0 })
                    .max(by: { ($0.2 * $0.3) <= ($1.2 * $1.3) }) else {
                    return nil
                }
                r = best
            }
            return r
        }
    }
}
