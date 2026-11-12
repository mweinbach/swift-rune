import Foundation
import Rune

struct XYChartSeries: Sendable {
    enum Kind: Sendable, Equatable {
        case bar
        case line
    }

    var kind: Kind
    var name: String
    var values: [Float]
}

struct XYChartDiagram: Sendable {
    var title: String?
    var horizontal: Bool = false
    var xTitle: String = ""
    var bands: [String] = []
    var xRange: (Float, Float)?
    var yTitle: String = ""
    var yRange: (Float, Float)?
    var series: [XYChartSeries] = []
}

enum XYChartParser {
    private static let plotHeight: Float = 240.0

    static func parse(header: String, body: [String]) -> XYChartDiagram? {
        var x = XYChartDiagram(horizontal: header.trimmingCharacters(in: .whitespaces) == "horizontal")
        var items = 0
        for l in body {
            if let rest = word(l, "title") {
                let t = cleanQuoted(rest)
                x.title = t.isEmpty ? nil : t
            } else if let rest = word(l, "x-axis") {
                let (title, bands, range) = parseAxis(rest)
                items += bands.count
                x.xTitle = title
                x.bands = bands
                x.xRange = range
            } else if let rest = word(l, "y-axis") {
                let (title, _, range) = parseAxis(rest)
                x.yTitle = title
                x.yRange = range
            } else {
                let match: (XYChartSeries.Kind, String)? =
                    word(l, "bar").map { (.bar, $0) } ?? word(l, "line").map { (.line, $0) }
                if let (kind, rest) = match, let open = rest.firstIndex(of: "[") {
                    let parsed = parseList(String(rest[open...])).compactMap { v -> Float? in
                        guard let f = Float(v), f.isFinite else { return nil }
                        return f
                    }
                    if parsed.count == parseList(String(rest[open...])).count, !parsed.isEmpty {
                        items += parsed.count
                        x.series.append(XYChartSeries(kind: kind, name: cleanQuoted(String(rest[..<open])), values: parsed))
                    }
                }
            }
            if items > MermaidLimits.maxItems { return nil }
        }
        return x.series.isEmpty ? nil : x
    }

    private static func parseAxis(_ rest: String) -> (String, [String], (Float, Float)?) {
        if let open = rest.firstIndex(of: "[") {
            let title = cleanQuoted(String(rest[..<open]))
            let bands = parseList(String(rest[open...])).map { cleanQuoted($0) }
            return (title, bands, nil)
        }
        if let arrow = rest.range(of: "-->") {
            let a = rest[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let b = rest[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            let title: String
            let loStr: String
            if let ws = a.lastIndex(where: \.isWhitespace) {
                title = String(a[..<ws])
                loStr = String(a[a.index(after: ws)...])
            } else {
                title = ""
                loStr = a
            }
            if let lo = Float(loStr), let hi = Float(b), lo.isFinite, hi.isFinite, lo != hi {
                return (cleanQuoted(title), [], (min(lo, hi), max(lo, hi)))
            }
        }
        return (cleanQuoted(rest), [], nil)
    }

    private static func parseList(_ s: String) -> [String] {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.lastIndex(of: "]"), close > trimmed.startIndex else {
            return []
        }
        let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        var out: [String] = []
        var cur = ""
        var quoted = false
        for ch in inner {
            if ch == "\"" {
                quoted.toggle()
                cur.append(ch)
            } else if ch == "," && !quoted {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur.removeAll(keepingCapacity: true)
            } else {
                cur.append(ch)
            }
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    private static func nice(_ raw: Float) -> Float {
        let p = powf(10.0, floorf(log10f(max(raw, 1e-9))))
        let m = raw / p
        if m <= 1.0 { return p * 1.0 }
        if m <= 2.0 { return p * 2.0 }
        if m <= 5.0 { return p * 5.0 }
        return p * 10.0
    }

    static func scale(range: (Float, Float)?, series: [XYChartSeries]) -> ((Float, Float), [Float]) {
        let (lo, hi): (Float, Float) = range ?? {
            var a: Float = 0.0
            var b: Float = 0.0
            for s in series {
                for v in s.values {
                    a = min(a, v)
                    b = max(b, v)
                }
            }
            let hiAdj = (b - a < 1e-9) ? (a + 1.0) : b
            let step = nice((hiAdj - a) / 5.0)
            return (floorf(a / step) * step, ceilf(hiAdj / step) * step)
        }()
        let step = nice((hi - lo) / 5.0)
        let first = ceilf(lo / step)
        var ticks: [Float] = []
        for k in 0..<12 {
            let t = (first + Float(k)) * step
            if t > hi + step * 1e-3 { break }
            ticks.append(abs(t) < step * 1e-3 ? 0.0 : t)
        }
        return ((lo, hi), ticks)
    }

    static func draw(_ x: XYChartDiagram, paint: MermaidTheme) -> MermaidScene? {
        guard let n = x.series.map({ $0.values.count }).max(), n > 0 else { return nil }
        let note = MermaidChart.small(paint)
        let ((lo, hi), ticks) = scale(range: x.yRange, series: x.series)
        let names: [String]
        if !x.bands.isEmpty {
            names = (0..<n).map { i in i < x.bands.count ? x.bands[i] : "" }
        } else if let (a, b) = x.xRange {
            let denom = Float(max(n, 2) - 1)
            names = (0..<n).map { i in PieParser.formatNumber(Double(a + (b - a) * Float(i) / denom)) }
        } else {
            names = Array(repeating: "", count: n)
        }

        var c = Canvas()
        var top: Float = 0.0
        if x.series.contains(where: { !$0.name.isEmpty }) {
            var at: Float = 0.0
            var h: Float = 0.0
            for (i, s) in x.series.enumerated() {
                let m = measureText(s.name, font: note)
                c.fill(CanvasMath.ellipse(center: Vec2(at + 5.0, m.size.y * 0.5), rx: 5.0, ry: 5.0), color: MermaidChart.solid(paint, hue: MermaidChart.hue(i)))
                c.labelAt(m, at: Vec2(at + 14.0, 0.0), font: note, color: paint.muted, align: .leading)
                at += 14.0 + m.size.x + 16.0
                h = max(h, m.size.y)
            }
            top = h + 12.0
        }

        let valueTitle = measureText(x.yTitle, font: note)
        let bandTitle = measureText(x.xTitle, font: note)
        let values = ticks.map { t in (t, measureText(PieParser.formatNumber(Double(t)), font: note)) }
        func v01(_ v: Float) -> Float { min(max((v - lo) / (hi - lo), 0.0), 1.0) }
        let base = v01(0.0)

        let x0: Float
        let y0: Float
        let x1: Float
        let y1: Float
        let labels: [Measured]

        if x.horizontal {
            labels = names.map { measureWrap($0, font: note, maxWidth: 120.0) }
            let lw = labels.map { $0.size.x }.max() ?? 0.0
            let bandH = max((labels.map { $0.size.y }.max() ?? 0.0) + 10.0, 26.0)
            if !bandTitle.text.isEmpty {
                c.labelAt(bandTitle, at: Vec2(0.0, top), font: note, color: paint.muted, align: .leading)
                top += bandTitle.size.y + 6.0
            }
            x0 = lw > 0.0 ? lw + 10.0 : 0.0
            y0 = top
            x1 = max(Canvas.room(for: paint), x0 + 200.0)
            y1 = y0 + bandH * Float(n)
        } else {
            let vw = values.map { $0.1.size.x }.max() ?? 0.0
            if !valueTitle.text.isEmpty {
                c.labelAt(valueTitle, at: Vec2(0.0, top), font: note, color: paint.muted, align: .leading)
                top += valueTitle.size.y + 8.0
            }
            x0 = vw + 10.0
            y0 = top
            x1 = max(Canvas.room(for: paint), x0 + 200.0)
            y1 = top + plotHeight
            let bandW = (x1 - x0) / Float(n)
            labels = names.map { measureWrap($0, font: note, maxWidth: max(bandW - 4.0, 24.0)) }
        }

        let length = x.horizontal ? (y1 - y0) : (x1 - x0)
        let band = length / Float(n)
        func point(_ u: Float, _ v: Float) -> Vec2 {
            x.horizontal ? Vec2(x0 + v * (x1 - x0), y0 + u) : Vec2(x0 + u, y1 - v * (y1 - y0))
        }

        if x.horizontal {
            let xTicks = values.map { (t, m) in (point(0.0, v01(t)).x, m) }
            MermaidChart.axisX(&c, ticks: xTicks, xRange: (x0, x1), yRange: (y0, y1), font: note, paint: paint)
            if !valueTitle.text.isEmpty {
                let h = values.map { $0.1.size.y }.max() ?? 0.0
                c.label(valueTitle, center: Vec2((x0 + x1) * 0.5, y1 + h + 14.0 + valueTitle.size.y * 0.5), font: note, color: paint.muted, align: .center)
            }
        } else {
            for (t, m) in values {
                let y = point(0.0, v01(t)).y
                c.stroke([Vec2(x0, y), Vec2(x1, y)], closed: false, width: 1.0, color: paint.text.alpha(0.08))
                c.labelAt(m, at: Vec2(x0 - 8.0 - m.size.x, y - m.size.y * 0.5), font: note, color: paint.muted, align: .trailing)
            }
        }
        c.stroke([point(0.0, base), point(length, base)], closed: false, width: 1.0, color: paint.surfaceBorder)

        for (i, m) in labels.enumerated() {
            let mid = (Float(i) + 0.5) * band
            if x.horizontal {
                c.labelAt(m, at: Vec2(x0 - 10.0 - m.size.x, y0 + mid - m.size.y * 0.5), font: note, color: paint.muted, align: .trailing)
            } else {
                c.labelAt(m, at: Vec2(x0 + mid - m.size.x * 0.5, y1 + 6.0), font: note, color: paint.muted, align: .center)
            }
        }
        if !x.horizontal && !bandTitle.text.isEmpty {
            let h = labels.map { $0.size.y }.max() ?? 0.0
            c.label(bandTitle, center: Vec2((x0 + x1) * 0.5, y1 + h + 14.0 + bandTitle.size.y * 0.5), font: note, color: paint.muted, align: .center)
        }

        let bars = x.series.indices.filter { x.series[$0].kind == .bar }
        let group = band * 0.72
        let each = group / Float(max(bars.count, 1))
        for (k, i) in bars.enumerated() {
            let fill = MermaidChart.solid(paint, hue: MermaidChart.hue(i))
            for (b, v) in x.series[i].values.enumerated() {
                let u0 = Float(b) * band + (band - group) * 0.5 + Float(k) * each + each * 0.06
                let u1 = u0 + each * 0.88
                let p = point(u0, base)
                let q = point(u1, v01(v))
                let ax = min(p.x, q.x), ay = min(p.y, q.y)
                let bx = max(p.x, q.x), by = max(p.y, q.y)
                c.fill([Vec2(ax, ay), Vec2(bx, ay), Vec2(bx, by), Vec2(ax, by)], color: fill)
            }
        }
        for (i, s) in x.series.enumerated() where s.kind == .line {
            let color = MermaidChart.solid(paint, hue: MermaidChart.hue(i))
            let pts = s.values.enumerated().map { (b, v) in point((Float(b) + 0.5) * band, v01(v)) }
            c.stroke(pts, closed: false, width: 2.0, color: color)
            for p in pts {
                c.shape(CanvasMath.ellipse(center: p, rx: 3.0, ry: 3.0), fill: color, border: paint.surface, width: 1.0)
            }
        }
        return c.finishFitMutating(paint: paint)
    }
}
