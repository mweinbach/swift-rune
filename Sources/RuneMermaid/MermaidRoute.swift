import Foundation
import Rune

enum RouteConstants {
    static let nodeGap: Float = 5.0
    static let clusterGap: Float = 2.0
    static let labelGap: Float = 2.0
    static let portGap: Float = 14.0
}

struct EdgeRoute {
    var curve: [Vec2]
    var tipStart: Vec2
    var tipEnd: Vec2
    var dirStart: Vec2
    var dirEnd: Vec2
    var label: Vec2?
}

struct RouteCtx {
    let placed: LayeredLayout.Placed
    var sizes: [Vec2]
    var shapes: [NodeShape]
    let labels: [Vec2?]
    let across: Bool
    var ends: [(Int, Int)]
    var centers: [Vec2]
    let real: Int
    var outlines: [[Vec2]]
    var titles: [(Float, Float, Float, Float)] = []
    var slots: [[Float?]] = []
    var homes: [[Int]] = []
    var stops: [Int] = []

    init(
        placed: LayeredLayout.Placed,
        sizes: [Vec2],
        shapes: [NodeShape],
        labels: [Vec2?],
        across: Bool,
        ends: [(Int, Int)]
    ) {
        self.placed = placed
        self.sizes = sizes
        self.shapes = shapes
        self.labels = labels
        self.across = across
        self.ends = ends
        self.centers = placed.centers
        self.real = sizes.count
        let swap: (Vec2) -> Vec2 = { p in across ? Vec2(p.y, p.x) : p }
        self.outlines = (0..<sizes.count).map { v in
            ShapeRenderer.outline(shape: shapes[v], center: swap(placed.centers[v]), size: sizes[v]).map(swap)
        }
    }

    func withHomes(_ nodeHomes: [[Int]], chains: [[Int]]) -> RouteCtx {
        var copy = self
        copy.homes = nodeHomes + stops.map { chains[$0] }
        return copy
    }

    private func foreign(_ i: Int) -> [(Float, Float, Float, Float)] {
        let (from, to) = ends[i]
        func home(_ v: Int, _ c: Int) -> Bool {
            v < homes.count && homes[v].contains(c)
        }
        return placed.clusters.enumerated().compactMap { (c, b) in
            if b == (0, 0, 0, 0) || home(from, c) || home(to, c) { return nil }
            return b
        }
    }

    func withClusterEnds(_ on: [(Int?, Int?)]) -> RouteCtx {
        var copy = self
        var boxes: [(Int, Int)] = []
        for (i, pair) in on.prefix(ends.count).enumerated() {
            for (k, cOpt) in [pair.0, pair.1].enumerated() {
                guard let c = cOpt, c < placed.clusters.count else { continue }
                let b = placed.clusters[c]
                if b == (0, 0, 0, 0) { continue }
                let v: Int
                if let existing = boxes.first(where: { $0.0 == c }) {
                    v = existing.1
                } else {
                    let ctr = Vec2((b.0 + b.2) * 0.5, (b.1 + b.3) * 0.5)
                    let sz = copy.screen(Vec2(b.2 - b.0, b.3 - b.1))
                    let shape = NodeShape.rect
                    copy.outlines.append(ShapeRenderer.outline(shape: shape, center: copy.screen(ctr), size: sz).map { copy.screen($0) })
                    copy.centers.append(ctr)
                    copy.sizes.append(sz)
                    copy.shapes.append(shape)
                    let idx = copy.sizes.count - 1
                    boxes.append((c, idx))
                    copy.stops.append(c)
                    v = idx
                }
                if k == 0 {
                    copy.ends[i].0 = v
                } else {
                    copy.ends[i].1 = v
                }
            }
        }
        return copy
    }

    func withTitles(_ titleBoxes: [(Float, Float, Float, Float)]) -> RouteCtx {
        var copy = self
        copy.titles = titleBoxes.map { r in
            let a = screen(Vec2(r.0, r.1))
            let b = screen(Vec2(r.2, r.3))
            return (a.x, a.y, b.x, b.y)
        }
        return copy
    }

    func fanned(flip: Bool) -> RouteCtx {
        var copy = self
        struct EndEntry {
            let node: Int
            let side: Int
            let portX: Float
            let otherX: Float
            let edge: Int
            let which: Int
        }
        var list: [EndEntry] = []
        for i in 0..<ends.count {
            let (from, to) = ends[i]
            if from == to || i >= placed.paths.count || placed.paths[i].count < 2 { continue }
            let r = route(i, flip: flip, insets: (0, 0))
            let a = screen(r.tipStart)
            let b = screen(r.tipEnd)
            func side(_ d: Vec2) -> Int { screen(d).y > 0 ? -1 : 1 }
            list.append(EndEntry(node: from, side: side(r.dirStart), portX: a.x, otherX: b.x, edge: i, which: 0))
            list.append(EndEntry(node: to, side: side(r.dirEnd), portX: b.x, otherX: a.x, edge: i, which: 1))
        }
        list.sort {
            if $0.node != $1.node { return $0.node < $1.node }
            if $0.side != $1.side { return $0.side < $1.side }
            return $0.portX < $1.portX
        }
        copy.slots = Array(repeating: [nil, nil], count: ends.count)
        var start = 0
        while start < list.count {
            var end = start + 1
            while end < list.count && list[end].node == list[start].node && list[end].side == list[start].side {
                end += 1
            }
            let group = Array(list[start..<end])
            let c = centers[group[0].node].x
            let reach = fanReach(group[0].node)
            let xs = RouteMath.spread(group: group.map { ($0.portX, $0.otherX, $0.edge) }, center: c, reach: reach)
            for (xVal, item) in zip(xs, group) {
                if abs(xVal - item.portX) > 0.5 {
                    copy.slots[item.edge][item.which] = xVal
                }
            }
            start = end
        }
        return copy
    }

    private func slot(_ i: Int) -> (Float?, Float?) {
        guard i < slots.count else { return (nil, nil) }
        return (slots[i][0], slots[i][1])
    }

    func onBorder(_ r: (Float, Float, Float, Float)) -> Bool {
        let a = screen(Vec2(r.0, r.1))
        let b = screen(Vec2(r.2, r.3))
        let rect = (min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
        return placed.clusters.contains { c in
            c != (0, 0, 0, 0) && RouteMath.straddles(rect, c)
        }
    }

    func screen(_ p: Vec2) -> Vec2 {
        across ? Vec2(p.y, p.x) : p
    }

    func size(_ v: Int) -> Vec2 {
        screen(sizes[v])
    }

    private func portReach(_ v: Int) -> Float {
        let half = size(v).x * 0.5
        let flat: Bool = switch shapes[v] {
        case .cylinder, .linedCylinder: !across
        default: shapes[v].isFlat
        }
        if flat { return max(half - 10.0, half * 0.5) }
        switch shapes[v] {
        case .stadium where !across: return max(half - size(v).y * 0.5 - 2.0, half * 0.4)
        case .hexagon where !across: return max(half - size(v).y * 0.25 - 6.0, half * 0.4)
        case .diamond, .hexagon: return half * 0.6
        default: return half * 0.45
        }
    }

    private func fanReach(_ v: Int) -> Float {
        let flat: Bool = switch shapes[v] {
        case .cylinder, .linedCylinder: !across
        default: shapes[v].isFlat
        }
        let reach = portReach(v)
        return flat ? max(reach, size(v).x * 0.5 - 6.0) : reach
    }

    private func port(_ v: Int, x: Float, s: Float) -> Vec2 {
        let c = centers[v].x
        let r = portReach(v)
        return portWithin(v, x: min(max(x, c - r), c + r), s: s)
    }

    private func portWithin(_ v: Int, x: Float, s: Float) -> Vec2 {
        let c = centers[v]
        let r = fanReach(v)
        let clampedX = min(max(x, c.x - r), c.x + r)
        let poly = outlines[v]
        var best: Float? = nil
        if !poly.isEmpty {
            for i in 0..<poly.count {
                let a = poly[i]
                let b = poly[(i + 1) % poly.count]
                if (a.x - clampedX) * (b.x - clampedX) > 0.0 || abs(a.x - b.x) < 1e-4 {
                    continue
                }
                let y = a.y + (b.y - a.y) * (clampedX - a.x) / (b.x - a.x)
                if let bY = best {
                    if (y - bY) * s > 0.0 { best = y }
                } else {
                    best = y
                }
            }
        }
        if let y = best, (y - c.y) * s >= 0.0 {
            return Vec2(clampedX, y)
        }
        let t = ShapeRenderer.boundary(shape: shapes[v], center: screen(c), size: sizes[v], toward: screen(Vec2(clampedX, c.y + s * 1e4)))
        return screen(t)
    }

    private func clearOf(_ v: Int, p: Vec2, gap: Float) -> Bool {
        let c = centers[v]
        let s = size(v)
        if abs(p.x - c.x) > s.x * 0.5 + gap || abs(p.y - c.y) > s.y * 0.5 + gap {
            return true
        }
        let poly = outlines[v]
        if RouteMath.inside(poly, p) { return false }
        for i in 0..<poly.count {
            if RouteMath.segDist(p, poly[i], poly[(i + 1) % poly.count]) <= gap {
                return false
            }
        }
        return true
    }

    private func labelBoxes(skip: Int) -> [(Float, Float, Float, Float)] {
        var out: [(Float, Float, Float, Float)] = []
        for j in 0..<labels.count where j != skip {
            if let at = placed.labels[j], let s = labels[j] {
                out.append((at.x - s.x * 0.5, at.y - s.y * 0.5, at.x + s.x * 0.5, at.y + s.y * 0.5))
            }
        }
        out.append(contentsOf: titles)
        return out
    }

    private func isClear(edge: Int, a: Vec2, b: Vec2, ends: (Int, Int)) -> Bool {
        let c = RouteMath.cubic(a, b)
        var pts: [Vec2] = []
        for i in 0..<(c.count - 1) {
            let w0 = c[i], w1 = c[i + 1]
            let steps = Int(max(ceilf(CanvasMath.dist(w0, w1) / 3.0), 1.0))
            for k in 0..<steps {
                pts.append(CanvasMath.lerp(w0, w1, Float(k) / Float(steps)))
            }
        }
        pts.append(b)
        let boxes = labelBoxes(skip: edge)
        let foreignBoxes = foreign(edge)
        let g = RouteConstants.clusterGap
        for p in pts {
            for v in 0..<real where v != ends.0 && v != ends.1 {
                if !clearOf(v, p: p, gap: RouteConstants.nodeGap) { return false }
            }
            for r in boxes {
                if p.x >= r.0 && p.x <= r.2 && p.y >= r.1 && p.y <= r.3 { return false }
            }
            for r in foreignBoxes {
                if p.x >= r.0 - g && p.x <= r.2 + g && p.y >= r.1 - g && p.y <= r.3 + g { return false }
            }
        }
        return true
    }

    func route(_ i: Int, flip: Bool, insets: (Float, Float)) -> EdgeRoute {
        let (from, to) = ends[i]
        var path = placed.paths[i]
        if flip { path.reverse() }
        let label = placed.labels[i]
        let twin = ends.enumerated().contains { (j, pair) in
            j != i && (pair == (from, to) || pair == (to, from))
        }
        let labelAt = label.flatMap { l in path.firstIndex(of: l) }
        var anchors = computeAnchors(i, path: path, all: twin, at: nil)
        var at = label

        if let l = label, let sz = labels[i], !twin {
            let line = RouteMath.curve(anchors)
            func upright(_ p: Vec2) -> Bool {
                if let a = RouteMath.along(line, y: p.y - sz.y * 0.5),
                   let b = RouteMath.along(line, y: p.y + sz.y * 0.5) {
                    return abs(a - b) < 1.0
                }
                return false
            }
            if let xOn = RouteMath.along(line, y: l.y),
               upright(Vec2(xOn, l.y)),
               labelFits(i, p: Vec2(xOn, l.y), size: sz) {
                at = Vec2(xOn, l.y)
            } else {
                anchors = computeAnchors(i, path: path, all: false, at: labelAt)
                if let k = anchors.firstIndex(of: l), k > 0, k + 1 < anchors.count {
                    let sign: Float = anchors[k + 1].y >= anchors[k - 1].y ? 1.0 : -1.0
                    let h = sz.y * 0.5 * sign
                    anchors.replaceSubrange(k...k, with: [Vec2(l.x, l.y - h), Vec2(l.x, l.y + h)])
                }
            }
        }

        let n = anchors.count
        let s0: Float = anchors[1].y >= anchors[0].y ? 1.0 : -1.0
        let s1: Float = anchors[n - 1].y >= anchors[n - 2].y ? 1.0 : -1.0
        let tipStart = anchors[0]
        let tipEnd = anchors[n - 1]
        if abs(anchors[1].y - anchors[0].y) > insets.0 + 4.0 {
            anchors[0].y += s0 * insets.0
        }
        if abs(anchors[n - 1].y - anchors[n - 2].y) > insets.1 + 4.0 {
            anchors[n - 1].y -= s1 * insets.1
        }
        return EdgeRoute(
            curve: RouteMath.curve(anchors).map { screen($0) },
            tipStart: screen(tipStart),
            tipEnd: screen(tipEnd),
            dirStart: screen(Vec2(0, -s0)),
            dirEnd: screen(Vec2(0, s1)),
            label: at.map { screen($0) }
        )
    }

    private func computeAnchors(_ i: Int, path: [Vec2], all: Bool, at: Int?) -> [Vec2] {
        func keep(_ k: Int) -> Bool { all || k == at }
        let (from, to) = ends[i]
        let n = path.count
        let endsPair = (from, to)
        let s0: Float = path[1].y >= path[0].y ? 1.0 : -1.0
        let s1: Float = path[n - 1].y >= path[n - 2].y ? 1.0 : -1.0
        if !all && at == nil, let pair = direct(i, path: path, s0: s0, s1: s1) {
            return pair
        }
        var pts = path
        pts[0] = port(from, x: path[1].x, s: s0)
        pts[n - 1] = port(to, x: path[n - 2].x, s: -s1)

        var kept = [0]
        var k = 0
        while k < n - 1 {
            let stop = ((k + 1)..<n).first(where: { $0 == n - 1 || keep($0) }) ?? (n - 1)
            let next = ((k + 1)...stop).reversed().first(where: { $0 == k + 1 || isClear(edge: i, a: pts[k], b: pts[$0], ends: endsPair) }) ?? (k + 1)
            kept.append(next)
            k = next
        }
        var out = kept.map { pts[$0] }
        let m = out.count
        let c0 = centers[from].x, c1 = centers[to].x
        let r0 = portReach(from), r1 = portReach(to)
        let lo = max(c0 - r0, c1 - r1), hi = min(c0 + r0, c1 + r1)
        let wanted: (Float, Float)
        if m == 2 && lo <= hi {
            let midSum = path.dropFirst().dropLast().reduce(Float(0)) { $0 + $1.x }
            let mid = midSum / Float(max(n - 2, 1))
            let x = n > 2 ? min(max(mid, lo), hi) : min(max((c0 + c1) * 0.5, lo), hi)
            wanted = (x, x)
        } else {
            wanted = (out[1].x, out[m - 2].x)
        }

        let sl = slot(i)
        if m == 2 {
            let facing = (out[m - 1].x, out[0].x)
            let fanned = (sl.0 ?? wanted.0, sl.1 ?? wanted.1)
            for (x0, x1) in [fanned, wanted, facing] {
                let a = portWithin(from, x: x0, s: s0)
                let b = portWithin(to, x: x1, s: -s1)
                if isClear(edge: i, a: a, b: b, ends: endsPair) {
                    out[0] = a
                    out[m - 1] = b
                    break
                }
            }
        } else {
            func near(_ v: Int, toward: Vec2, s: Float, first: Bool) -> Vec2? {
                let c = centers[v].x, r = portReach(v)
                var xs = (0...8).map { k in c - r + 2.0 * r * Float(k) / 8.0 }
                xs.append(min(max(toward.x, c - r), c + r))
                xs.sort { abs($0 - toward.x) < abs($1 - toward.x) }
                if let x = (first ? sl.0 : sl.1) {
                    xs.insert(x, at: 0)
                }
                for x in xs {
                    let p = portWithin(v, x: x, s: s)
                    if first ? isClear(edge: i, a: p, b: toward, ends: endsPair) : isClear(edge: i, a: toward, b: p, ends: endsPair) {
                        return p
                    }
                }
                return nil
            }
            if let a = near(from, toward: out[1], s: s0, first: true) { out[0] = a }
            if let b = near(to, toward: out[m - 2], s: -s1, first: false) { out[m - 1] = b }
        }
        return out
    }

    private func direct(_ i: Int, path: [Vec2], s0: Float, s1: Float) -> [Vec2]? {
        let tries = 16
        let (from, to) = ends[i]
        let c0 = centers[from].x, c1 = centers[to].x
        let r0 = portReach(from), r1 = portReach(to)
        var xs = path.dropFirst().dropLast().map(\.x)
        xs.append(contentsOf: [c0, c1, c0 - r0, c0 + r0, c1 - r1, c1 + r1])
        var pairs: [(Float, Float)] = []
        for a in xs {
            for b in xs {
                pairs.append((min(max(a, c0 - r0), c0 + r0), min(max(b, c1 - r1), c1 + r1)))
            }
        }
        func best(_ input: [(Float, Float)]) -> [Vec2]? {
            let sorted = input.sorted {
                let ca = abs($0.0 - $0.1) * 4.0 + abs($0.0 - c0) + abs($0.1 - c1)
                let cb = abs($1.0 - $1.1) * 4.0 + abs($1.0 - c0) + abs($1.1 - c1)
                return ca < cb
            }
            var dedup: [(Float, Float)] = []
            for p in sorted {
                if let last = dedup.last, abs(p.0 - last.0) < 0.5 && abs(p.1 - last.1) < 0.5 {
                    continue
                }
                dedup.append(p)
                if dedup.count >= tries { break }
            }
            for (x0, x1) in dedup {
                let a = portWithin(from, x: x0, s: s0)
                let b = portWithin(to, x: x1, s: -s1)
                if isClear(edge: i, a: a, b: b, ends: (from, to)) {
                    return [a, b]
                }
            }
            return nil
        }
        let sl = slot(i)
        if sl.0 != nil || sl.1 != nil {
            if let res = best(pairs.map { (sl.0 ?? $0.0, sl.1 ?? $0.1) }) {
                return res
            }
        }
        return best(pairs)
    }

    private func labelFits(_ i: Int, p: Vec2, size: Vec2) -> Bool {
        let hw = size.x * 0.5 + RouteConstants.labelGap
        let hh = size.y * 0.5 + RouteConstants.labelGap
        let corners = [
            Vec2(p.x - hw, p.y - hh),
            Vec2(p.x + hw, p.y - hh),
            Vec2(p.x + hw, p.y + hh),
            Vec2(p.x - hw, p.y + hh),
            p,
        ]
        for v in 0..<real {
            let c = centers[v], s = self.size(v)
            let apart = abs(p.x - c.x) > hw + s.x * 0.5 || abs(p.y - c.y) > hh + s.y * 0.5
            if !apart {
                if corners.contains(where: { RouteMath.inside(outlines[v], $0) }) { return false }
                if outlines[v].contains(where: { abs($0.x - p.x) <= hw && abs($0.y - p.y) <= hh }) { return false }
            }
        }
        let rect = (p.x - hw, p.y - hh, p.x + hw, p.y + hh)
        if placed.clusters.contains(where: { $0 != (0, 0, 0, 0) && RouteMath.straddles(rect, $0) }) {
            return false
        }
        for r in labelBoxes(skip: i) {
            if !(p.x + hw < r.0 || p.x - hw > r.2 || p.y + hh < r.1 || p.y - hh > r.3) {
                return false
            }
        }
        return true
    }
}

enum RouteMath {
    static func cubic(_ a: Vec2, _ b: Vec2) -> [Vec2] {
        let dy = b.y - a.y
        if abs(b.x - a.x) < 0.25 { return [a, b] }
        let c1 = Vec2(a.x, a.y + dy * 0.5)
        let c2 = Vec2(b.x, b.y - dy * 0.5)
        let len = CanvasMath.dist(a, c1) + CanvasMath.dist(c1, c2) + CanvasMath.dist(c2, b)
        let steps = Int(min(max(ceilf(len / 3.0), 8.0), 96.0))
        return (0...steps).map { s in
            let t = Float(s) / Float(steps)
            let u = 1.0 - t
            let b0 = u * u * u
            let b1 = 3.0 * u * u * t
            let b2 = 3.0 * u * t * t
            let b3 = t * t * t
            return Vec2(
                b0 * a.x + b1 * c1.x + b2 * c2.x + b3 * b.x,
                b0 * a.y + b1 * c1.y + b2 * c2.y + b3 * b.y
            )
        }
    }

    static func curve(_ anchors: [Vec2]) -> [Vec2] {
        guard !anchors.isEmpty else { return [] }
        var out = [anchors[0]]
        for i in 0..<(anchors.count - 1) {
            out.append(contentsOf: cubic(anchors[i], anchors[i + 1]).dropFirst())
        }
        return out
    }

    static func spread(group: [(portX: Float, otherX: Float, edge: Int)], center c: Float, reach: Float) -> [Float] {
        guard !group.isEmpty else { return [] }
        var order = Array(0..<group.count)
        var runs: [Range<Int>] = []
        for k in 0..<group.count {
            if let last = runs.last, group[k].portX - group[k - 1].portX < RouteConstants.portGap {
                runs[runs.count - 1] = last.lowerBound..<(k + 1)
            } else {
                runs.append(k..<(k + 1))
            }
        }
        var xs = Array(repeating: Float(0), count: group.count)
        for r in runs {
            order[r].sort { a, b in
                if group[a].otherX != group[b].otherX { return group[a].otherX < group[b].otherX }
                return group[a].edge < group[b].edge
            }
            let mid = group[r].reduce(Float(0)) { $0 + $1.portX } / Float(r.count)
            for (n, k) in r.enumerated() {
                xs[k] = mid + (Float(n) - Float(r.count - 1) * 0.5) * RouteConstants.portGap
            }
        }
        for k in 1..<xs.count {
            xs[k] = max(xs[k], xs[k - 1] + RouteConstants.portGap)
        }
        let lo = c - reach, hi = c + reach
        let span = xs[xs.count - 1] - xs[0]
        if span > hi - lo {
            let n = Float(max(xs.count - 1, 1))
            for k in 0..<xs.count {
                xs[k] = lo + (hi - lo) * Float(k) / n
            }
        } else {
            let shift = max(lo - xs[0], 0.0) + min(hi - xs[xs.count - 1], 0.0)
            for k in 0..<xs.count {
                xs[k] += shift
            }
        }
        var out = Array(repeating: Float(0), count: group.count)
        for (k, g) in order.enumerated() {
            out[g] = xs[k]
        }
        return out
    }

    static func along(_ pts: [Vec2], y: Float) -> Float? {
        guard pts.count >= 2 else { return nil }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            if (a.y - y) * (b.y - y) > 0.0 || abs(a.y - b.y) < 1e-5 { continue }
            return a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y)
        }
        return nil
    }

    static func straddles(_ r: (Float, Float, Float, Float), _ c: (Float, Float, Float, Float)) -> Bool {
        let overlaps = r.0 < c.2 && r.2 > c.0 && r.1 < c.3 && r.3 > c.1
        let within = r.0 >= c.0 && r.2 <= c.2 && r.1 >= c.1 && r.3 <= c.3
        return overlaps && !within
    }

    static func inside(_ poly: [Vec2], _ p: Vec2) -> Bool {
        var odd = false
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            if (a.y > p.y) != (b.y > p.y), p.x < a.x + (b.x - a.x) * (p.y - a.y) / (b.y - a.y) {
                odd.toggle()
            }
        }
        return odd
    }

    static func segDist(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Float {
        let dx = b.x - a.x, dy = b.y - a.y
        let l = dx * dx + dy * dy
        let t: Float = l < 1e-6 ? 0.0 : min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / l, 0.0), 1.0)
        return CanvasMath.dist(p, Vec2(a.x + dx * t, a.y + dy * t))
    }
}
