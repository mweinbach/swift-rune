import Foundation
import Rune

struct PieDiagram: Sendable {
    var title: String?
    var showData: Bool
    var slices: [(String, Double)]
}

enum PieParser {
    private static let radius: Float = 100.0
    private static let swatch: Float = 12.0

    static func parse(header: String, body: [String]) -> PieDiagram? {
        var p = PieDiagram(title: nil, showData: false, slices: [])
        for line in [header] + body {
            for stmt in statements(line) {
                var s = stmt
                if s.hasPrefix("showData") {
                    p.showData = true
                    s = String(s.dropFirst("showData".count)).trimmingCharacters(in: .whitespaces)
                }
                if s.hasPrefix("title") {
                    let rest = String(s.dropFirst("title".count))
                    if rest.isEmpty || rest.first?.isWhitespace == true {
                        let t = cleanQuoted(rest)
                        p.title = t.isEmpty ? nil : t
                        continue
                    }
                }
                if s.isEmpty || s.hasPrefix("accTitle") || s.hasPrefix("accDescr") {
                    continue
                }
                guard let colon = s.lastIndex(of: ":") else { continue }
                let label = String(s[..<colon])
                let valueStr = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard let v = Double(valueStr), v.isFinite, v > 0.0 else { continue }
                if p.slices.count >= MermaidLimits.maxItems { return nil }
                p.slices.append((cleanQuoted(label), v))
            }
        }
        return p.slices.isEmpty ? nil : p
    }

    static func formatNumber(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1.0) == 0.0 && abs(v) < 1e15 {
            return String(format: "%.0f", v)
        }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func draw(_ p: PieDiagram, paint: MermaidTheme) -> MermaidScene? {
        let small = MermaidChart.small(paint)
        let pctFont = MermaidChart.bold(small)
        let total = p.slices.reduce(0.0) { $0 + $1.1 }
        guard total > 0 else { return nil }

        let names = p.slices.map { measureText($0.0, font: paint.font) }
        let values: [Measured?] = p.slices.map { p.showData ? measureText(formatNumber($0.1), font: paint.font) : nil }
        let lh = paint.font.lineHeight ?? (paint.font.size * 1.38)
        let rowH = max(lh, swatch) + 6.0

        var legendW: Float = 0.0
        for (n, v) in zip(names, values) {
            let w = swatch + 8.0 + n.size.x + (v.map { $0.size.x + 8.0 } ?? 0.0)
            legendW = max(legendW, w)
        }
        let legendH = Float(p.slices.count) * rowH - 6.0
        let beside = 2.0 * radius + 32.0 + legendW <= Canvas.room(for: paint)

        let centre: Vec2
        let legend: Vec2
        if beside {
            let h = max(legendH, 2.0 * radius)
            centre = Vec2(radius, h * 0.5)
            legend = Vec2(2.0 * radius + 32.0, (h - legendH) * 0.5)
        } else {
            centre = Vec2(max(radius, legendW * 0.5), radius)
            legend = Vec2(max(radius - legendW * 0.5, 0.0), 2.0 * radius + 20.0)
        }

        var c = Canvas()
        var a: Float = -90.0
        var edges: [Float] = []
        for (i, s) in p.slices.enumerated() {
            let sweep = Float(s.1 / total) * 360.0
            let steps = max(Int((sweep / 4.0).rounded(.up)), 2)
            var pts = CanvasMath.arc(center: centre, rx: radius, ry: radius, a0: a, a1: a + sweep, steps: steps)
            if p.slices.count > 1 {
                pts.append(centre)
            }
            c.fill(pts, color: MermaidChart.solid(paint, hue: MermaidChart.hue(i)))
            edges.append(a)
            a += sweep
        }
        if p.slices.count > 1 {
            for edgeA in edges {
                let rad = edgeA * .pi / 180.0
                c.stroke([centre, Vec2(centre.x + radius * cosf(rad), centre.y + radius * sinf(rad))], closed: false, width: 2.0, color: paint.surface)
            }
        }
        a = -90.0
        for (i, s) in p.slices.enumerated() {
            let frac = s.1 / total
            let sweep = Float(frac) * 360.0
            let m = measureText(String(format: "%.0f%%", frac * 100.0), font: pctFont)
            let halfRad = min(sweep * 0.5, 90.0) * .pi / 180.0
            let roomAcross = 2.0 * radius * 0.66 * sinf(halfRad)
            if p.slices.count == 1 || m.size.x + 6.0 <= roomAcross {
                let midRad = (a + sweep * 0.5) * .pi / 180.0
                let at = p.slices.count == 1 ? centre : Vec2(centre.x + radius * 0.66 * cosf(midRad), centre.y + radius * 0.66 * sinf(midRad))
                c.label(m, center: at, font: pctFont, color: MermaidChart.ink(MermaidChart.solid(paint, hue: MermaidChart.hue(i))), align: .center)
            }
            a += sweep
        }
        for (i, (n, v)) in zip(names, values).enumerated() {
            let y = legend.y + Float(i) * rowH
            let mid = y + (rowH - 6.0) * 0.5
            let x = legend.x
            c.fill(CanvasMath.roundedRect(x0: x, y0: mid - swatch * 0.5, x1: x + swatch, y1: mid + swatch * 0.5, r: 3.0), color: MermaidChart.solid(paint, hue: MermaidChart.hue(i)))
            c.labelAt(n, at: Vec2(x + swatch + 8.0, mid - n.size.y * 0.5), font: paint.font, color: paint.text, align: .leading)
            if let v {
                c.labelAt(v, at: Vec2(x + swatch + 16.0 + n.size.x, mid - v.size.y * 0.5), font: paint.font, color: paint.muted, align: .leading)
            }
        }
        return c.finish(scale: 1.0, paint: paint)
    }
}
