import Foundation
import Rune

struct JourneyTask: Equatable, Sendable {
    var name: String
    var score: Float
    var actors: [Int]
    var section: Int?
}

struct JourneyDiagram: Sendable {
    var title: String?
    var sections: [String] = []
    var actors: [String] = []
    var tasks: [JourneyTask] = []
}

enum JourneyParser {
    private static let colWidth: Float = 112.0
    private static let colGap: Float = 10.0
    private static let scoreStep: Float = 20.0
    private static let faceRadius: Float = 11.0
    private static let dotRadius: Float = 4.5

    static func parse(_ body: [String]) -> JourneyDiagram? {
        var j = JourneyDiagram()
        for l in body {
            if let rest = word(l, "title") {
                let s = clean(rest)
                j.title = s.isEmpty ? nil : s
                continue
            }
            if let rest = word(l, "section") {
                j.sections.append(clean(rest))
                continue
            }
            if l.hasPrefix("accTitle") || l.hasPrefix("accDescr") {
                continue
            }
            let parts = l.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2,
                  let score = Float(parts[1].trimmingCharacters(in: .whitespaces)),
                  score.isFinite else { continue }
            if j.tasks.count + j.sections.count >= MermaidLimits.maxItems { return nil }
            var actors: [Int] = []
            let rawActors = parts.count >= 3 ? parts[2] : ""
            for a in rawActors.split(separator: ",").map({ clean(String($0)) }).filter({ !$0.isEmpty }) {
                let idx: Int
                if let existing = j.actors.firstIndex(of: a) {
                    idx = existing
                } else {
                    j.actors.append(a)
                    idx = j.actors.count - 1
                }
                if !actors.contains(idx) {
                    actors.append(idx)
                }
            }
            let sec = j.sections.isEmpty ? nil : (j.sections.count - 1)
            j.tasks.append(JourneyTask(
                name: clean(parts[0]),
                score: min(max(score, 1.0), 5.0),
                actors: actors,
                section: sec
            ))
        }
        return j.tasks.isEmpty ? nil : j
    }

    private static func actorHue(_ i: Int) -> Float {
        MermaidChart.hue(i + 6)
    }

    static func mood(_ score: Float, paint: MermaidTheme) -> Color {
        let h = 25.0 + (score - 1.0) / 4.0 * 125.0
        return MermaidChart.isDark(paint) ? oklch(0.7, 0.14, h) : oklch(0.8, 0.14, h)
    }

    static func draw(_ j: JourneyDiagram, paint: MermaidTheme) -> MermaidScene? {
        let head = MermaidChart.bold(paint.font)
        let note = MermaidChart.small(paint)
        func xOf(_ i: Int) -> Float { Float(i) * (colWidth + colGap) }

        var c = Canvas()
        var y: Float = 0.0

        if !j.actors.isEmpty {
            var x: Float = 0.0
            let names = j.actors.map { measureText($0, font: note) }
            let h = names.map { $0.size.y }.max() ?? 0.0
            for (i, m) in names.enumerated() {
                c.fill(CanvasMath.ellipse(center: Vec2(x + dotRadius + 1.0, h * 0.5), rx: dotRadius + 1.0, ry: dotRadius + 1.0), color: MermaidChart.solid(paint, hue: actorHue(i)))
                c.labelAt(m, at: Vec2(x + 2.0 * dotRadius + 8.0, 0.0), font: note, color: paint.muted, align: .leading)
                x += 2.0 * dotRadius + 8.0 + m.size.x + 16.0
            }
            y = h + 12.0
        }

        if !j.sections.isEmpty {
            let titles = j.sections.map { measureWrap($0, font: head, maxWidth: 3.0 * colWidth) }
            let band = (titles.map { $0.size.y }.max() ?? 0.0) + 14.0
            for (s, m) in titles.enumerated() {
                let cols = j.tasks.indices.filter { j.tasks[$0].section == s }
                guard let a = cols.first, let b = cols.last else { continue }
                let fill = MermaidChart.solid(paint, hue: MermaidChart.hue(s))
                c.fill(CanvasMath.roundedRect(x0: xOf(a), y0: y, x1: xOf(b) + colWidth, y1: y + band, r: 6.0), color: fill)
                c.label(m, center: Vec2((xOf(a) + xOf(b) + colWidth) * 0.5, y + band * 0.5), font: head, color: MermaidChart.ink(fill), align: .center)
            }
            y += band + 8.0
        }

        let names = j.tasks.map { measureWrap($0.name, font: paint.font, maxWidth: colWidth - 16.0) }
        let boxH = (names.map { $0.size.y }.max() ?? 0.0) + 20.0
        let facesTop = y + boxH + 22.0 + faceRadius
        let facesBottom = facesTop + 4.0 * scoreStep

        for (i, (t, m)) in zip(j.tasks, names).enumerated() {
            let x = xOf(i)
            let h = MermaidChart.hue(t.section ?? 0)
            let mid = x + colWidth * 0.5
            let face = Vec2(mid, facesTop + (5.0 - t.score) * scoreStep)
            c.dashed([Vec2(mid, y + boxH), Vec2(mid, facesBottom + faceRadius + 8.0)], width: 1.0, color: paint.text.alpha(0.25), on: 4.0, off: 3.0)
            c.shape(CanvasMath.roundedRect(x0: x, y0: y, x1: x + colWidth, y1: y + boxH, r: 6.0), fill: MermaidChart.soft(paint, hue: h), border: MermaidChart.strong(paint, hue: h), width: 1.0)
            c.label(m, center: Vec2(mid, y + boxH * 0.5 + 2.0), font: paint.font, color: paint.text, align: .center)
            for (k, a) in t.actors.enumerated() {
                c.shape(CanvasMath.ellipse(center: Vec2(x + 12.0 + Float(k) * (2.0 * dotRadius + 4.0), y), rx: dotRadius, ry: dotRadius), fill: MermaidChart.solid(paint, hue: actorHue(a)), border: paint.surface, width: 1.5)
            }
            drawFace(&c, at: face, score: t.score, paint: paint)
        }

        let base = facesBottom + faceRadius + 8.0
        let right = xOf(j.tasks.count - 1) + colWidth + 12.0
        c.stroke([Vec2(-4.0, base), Vec2(right - 8.0, base)], closed: false, width: 1.5, color: paint.line)
        c.fill(CanvasMath.arrowhead(tip: Vec2(right, base), dir: Vec2(1.0, 0.0), len: 9.0, width: 8.0), color: paint.line)
        return c.finishFitMutating(paint: paint)
    }

    private static func drawFace(_ c: inout Canvas, at: Vec2, score: Float, paint: MermaidTheme) {
        let line = oklch(0.25, 0.02, 60.0)
        c.shape(CanvasMath.ellipse(center: at, rx: faceRadius, ry: faceRadius), fill: mood(score, paint: paint), border: line.alpha(0.6), width: 1.0)
        for dx: Float in [-3.8, 3.8] {
            c.fill(CanvasMath.ellipse(center: Vec2(at.x + dx, at.y - 3.0), rx: 1.4, ry: 1.6), color: line)
        }
        let mouth: [Vec2]
        if score > 3.0 {
            mouth = CanvasMath.arc(center: Vec2(at.x, at.y + 1.0), rx: 5.0, ry: 4.0, a0: 20.0, a1: 160.0, steps: 12)
        } else if score < 3.0 {
            mouth = CanvasMath.arc(center: Vec2(at.x, at.y + 8.0), rx: 5.0, ry: 3.5, a0: 200.0, a1: 340.0, steps: 12)
        } else {
            mouth = [Vec2(at.x - 4.5, at.y + 4.5), Vec2(at.x + 4.5, at.y + 4.5)]
        }
        c.stroke(mouth, closed: false, width: 1.3, color: line)
    }
}
