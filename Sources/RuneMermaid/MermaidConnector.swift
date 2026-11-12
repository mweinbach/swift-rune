import Foundation
import Rune

enum ConnectorRenderer {
    private static let arrowLen: Float = 7.0

    static func labelBox(_ m: Measured) -> Vec2 {
        Vec2(m.size.x + 12.0, m.size.y + 6.0)
    }

    static func titleBox(_ m: Measured, at: Vec2) -> (Float, Float, Float, Float) {
        (at.x - 4.0, at.y - 4.0, at.x + m.size.x + 4.0, at.y + m.size.y + 4.0)
    }

    static func inset(for head: EdgeHead) -> Float {
        switch head {
        case .none: 0.0
        case .arrow: arrowLen * 0.7
        case .circle: 8.0
        case .contains: 12.0
        case .cross: 4.0
        case .openTriangle: 10.0
        case .diamondFilled, .diamondOpen: 12.0
        case .onlyOne, .zeroOrOne, .oneOrMore, .zeroOrMore: 0.0
        }
    }

    private static func pen(_ e: LayeredEdge, paint: MermaidTheme) -> (Color, Float) {
        let width = e.style.width ?? (e.line == .thick ? 2.5 : 1.25)
        let dark = paint.nodeFill.toOKLab()[0] < 0.5
        let color = e.style.stroke.map { adaptStroke(base: paint.line, color: $0, dark: dark) } ?? paint.line
        return (color, width)
    }

    static func drawEdges(
        into c: inout Canvas,
        ctx: RouteCtx,
        edges: [LayeredEdge],
        labels: [Measured?],
        backs: [Color],
        titles: [(Float, Float, Float, Float)],
        flip: Bool,
        font: TextStyle,
        paint: MermaidTheme
    ) {
        let routes: [(EdgeRoute, (Float, Float, Float, Float)?)?] = (0..<edges.count).map { i in
            let e = edges[i]
            guard ctx.placed.paths[i].count > 1 else { return nil }
            let r = ctx.route(i, flip: flip, insets: (inset(for: e.start), inset(for: e.end)))
            let gap: (Float, Float, Float, Float)?
            if let m = labels[i], let at = r.label {
                let s = labelBox(m)
                gap = (at.x - s.x * 0.5, at.y - s.y * 0.5, at.x + s.x * 0.5, at.y + s.y * 0.5)
            } else {
                gap = nil
            }
            return (r, gap)
        }

        for (i, e) in edges.enumerated() {
            c.part(.index(.edge, i))
            let start = c.ops.count
            let (color, _) = pen(e, paint: paint)
            let back = i < backs.count ? backs[i] : paint.surface
            var litLabel: (Int, (Float, Float, Float, Float), Color)? = nil

            if let (r, gap) = routes[i] {
                var runs = [r.curve]
                var obstacles: [(Float, Float, Float, Float)] = []
                if let g = gap { obstacles.append(g) }
                obstacles.append(contentsOf: titles)
                for (j, other) in routes.enumerated() where j != i {
                    if let g = other?.1 { obstacles.append(g) }
                }
                for rect in obstacles {
                    runs = runs.flatMap { outside(curve: $0, rect: rect) }
                }
                drawConnector(into: &c, runs: runs, tips: ((r.tipStart, r.dirStart), (r.tipEnd, r.dirEnd)), edge: e, paint: paint)
                if let m = labels[i], let at = r.label, let g = gap {
                    if ctx.onBorder(g) {
                        c.fill(CanvasMath.roundedRect(x0: g.0, y0: g.1, x1: g.2, y1: g.3, r: 4.0), color: back)
                    }
                    litLabel = (c.labels.count, g, back)
                    c.label(m, center: at, font: font, color: paint.muted, align: .center)
                }
            } else {
                let s = labels[i].map { labelBox($0).x } ?? 0.0
                let at = selfLoop(into: &c, edge: e, center: ctx.screen(ctx.placed.centers[e.from]), size: ctx.sizes[e.from], paint: paint)
                if let m = labels[i] {
                    let b = labelBox(m)
                    litLabel = (c.labels.count, (at.x, at.y - b.y * 0.5, at.x + b.x, at.y + b.y * 0.5), back)
                    c.label(m, center: Vec2(at.x + s * 0.5, at.y), font: font, color: paint.muted, align: .center)
                }
            }

            if let ll = litLabel, ll.0 < c.labels.count {
                c.trace(from: e.from, to: e.to, start: start, line: color, label: ll)
            } else {
                c.trace(from: e.from, to: e.to, start: start, line: color, label: nil)
            }
        }
        c.part(nil)
    }

    static func outside(curve: [Vec2], rect: (Float, Float, Float, Float)) -> [[Vec2]] {
        guard curve.count >= 2 else { return [] }
        var runs: [[Vec2]] = [[]]
        for i in 0..<(curve.count - 1) {
            let a = curve[i], b = curve[i + 1]
            if runs[runs.count - 1].isEmpty {
                runs[runs.count - 1].append(a)
            }
            if let (t0, t1) = insideSpan(a: a, b: b, rect: rect) {
                if t0 > 0.0 {
                    runs[runs.count - 1].append(CanvasMath.lerp(a, b, t0))
                }
                var next: [Vec2] = []
                if t1 < 1.0 {
                    next.append(CanvasMath.lerp(a, b, t1))
                    next.append(b)
                }
                runs.append(next)
            } else {
                runs[runs.count - 1].append(b)
            }
        }
        return runs.filter { $0.count >= 2 }
    }

    private static func insideSpan(a: Vec2, b: Vec2, rect: (Float, Float, Float, Float)) -> (Float, Float)? {
        let d = b - a
        var t0: Float = 0.0
        var t1: Float = 1.0
        let tests: [(Float, Float)] = [
            (-d.x, a.x - rect.0),
            (d.x, rect.2 - a.x),
            (-d.y, a.y - rect.1),
            (d.y, rect.3 - a.y),
        ]
        for (p, q) in tests {
            if abs(p) < 1e-9 {
                if q < 0.0 { return nil }
            } else {
                let r = q / p
                if p < 0.0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
            }
        }
        return t0 < t1 ? (t0, t1) : nil
    }

    static func drawConnector(
        into c: inout Canvas,
        runs: [[Vec2]],
        tips: ((Vec2, Vec2), (Vec2, Vec2)),
        edge e: LayeredEdge,
        paint: MermaidTheme
    ) {
        let (color, width) = pen(e, paint: paint)
        for run in runs {
            switch e.line {
            case .invisible: return
            case .dotted: c.dashed(run, width: width, color: color, on: 3.0, off: 3.0)
            case .solid, .thick: c.stroke(run, closed: false, width: width, color: color)
            }
        }
        drawHead(into: &c, head: e.end, tip: tips.1.0, dir: tips.1.1, width: width, color: color, paint: paint)
        drawHead(into: &c, head: e.start, tip: tips.0.0, dir: tips.0.1, width: width, color: color, paint: paint)
    }

    private static func drawHead(
        into c: inout Canvas,
        head h: EdgeHead,
        tip: Vec2,
        dir d: Vec2,
        width: Float,
        color: Color,
        paint: MermaidTheme
    ) {
        func back(_ by: Float) -> Vec2 { Vec2(tip.x - d.x * by, tip.y - d.y * by) }
        switch h {
        case .none:
            break
        case .arrow:
            c.fill(CanvasMath.arrowhead(tip: tip, dir: d, len: arrowLen + width, width: 5.0 + width * 1.6), color: color)
        case .openTriangle:
            c.shape(CanvasMath.arrowhead(tip: tip, dir: d, len: 10.0, width: 9.0), fill: paint.nodeFill, border: color, width: width)
        case .diamondFilled:
            c.fill(CanvasMath.diamondHead(tip: tip, dir: d, len: 12.0, width: 8.0), color: color)
        case .diamondOpen:
            c.shape(CanvasMath.diamondHead(tip: tip, dir: d, len: 12.0, width: 8.0), fill: paint.nodeFill, border: color, width: width)
        case .circle:
            c.shape(CanvasMath.ellipse(center: back(4.0), rx: 4.0, ry: 4.0), fill: paint.nodeFill, border: color, width: width)
        case .contains:
            let m = back(6.0)
            let n = Vec2(-d.y, d.x)
            c.shape(CanvasMath.ellipse(center: m, rx: 6.0, ry: 6.0), fill: paint.nodeFill, border: color, width: width)
            c.stroke([back(0.0), back(12.0)], closed: false, width: width, color: color)
            c.stroke([m + n * 6.0, m - n * 6.0], closed: false, width: width, color: color)
        case .cross:
            let m = back(4.0)
            let a = Vec2(d.x + d.y, d.y - d.x)
            let b = Vec2(d.x - d.y, d.y + d.x)
            let k = 3.5 / Float(2.0).squareRoot()
            c.stroke([m - a * k, m + a * k], closed: false, width: width, color: color)
            c.stroke([m - b * k, m + b * k], closed: false, width: width, color: color)
        case .onlyOne, .zeroOrOne, .oneOrMore, .zeroOrMore:
            drawCrow(into: &c, head: h, tip: tip, dir: d, width: width, color: color, paint: paint)
        }
    }

    private static func drawCrow(
        into c: inout Canvas,
        head h: EdgeHead,
        tip: Vec2,
        dir d: Vec2,
        width: Float,
        color: Color,
        paint: MermaidTheme
    ) {
        func back(_ by: Float) -> Vec2 { Vec2(tip.x - d.x * by, tip.y - d.y * by) }
        let n = Vec2(-d.y, d.x)
        func bar(_ at: Vec2) {
            c.stroke([at + n * 6.0, at - n * 6.0], closed: false, width: width, color: color)
        }
        let many = h == .oneOrMore || h == .zeroOrMore
        if many {
            let heel = back(12.0)
            for side: Float in [1.0, -1.0] {
                c.stroke([heel, tip + n * (6.5 * side)], closed: false, width: width, color: color)
            }
        } else {
            bar(back(5.0))
        }
        let inner: Float = many ? 16.0 : 10.0
        switch h {
        case .onlyOne, .oneOrMore:
            bar(back(inner))
        default:
            c.shape(CanvasMath.ellipse(center: back(inner + 4.0), rx: 4.0, ry: 4.0), fill: paint.surface, border: color, width: width)
        }
    }

    private static func selfLoop(
        into c: inout Canvas,
        edge e: LayeredEdge,
        center ctr: Vec2,
        size: Vec2,
        paint: MermaidTheme
    ) -> Vec2 {
        let x = ctr.x + size.x * 0.5
        let a = Vec2(x, ctr.y - size.y * 0.25)
        let b = Vec2(x, ctr.y + size.y * 0.25)
        var path = [a, Vec2(x + 18.0, a.y - 4.0), Vec2(x + 26.0, ctr.y), Vec2(x + 18.0, b.y + 4.0), b]
        let n = path.count
        let dirEnd = CanvasMath.unit(path[n - 2], path[n - 1])
        let dirStart = CanvasMath.unit(path[1], path[0])
        let tipEnd = path[n - 1]
        let tipStart = path[0]
        path[n - 1] = tipEnd - dirEnd * inset(for: e.end)
        path[0] = tipStart - dirStart * inset(for: e.start)
        drawConnector(into: &c, runs: [CanvasMath.smooth(path)], tips: ((tipStart, dirStart), (tipEnd, dirEnd)), edge: e, paint: paint)
        return Vec2(x + 30.0, ctr.y)
    }
}
