import Foundation
import Rune

struct TimelinePeriod: Sendable {
    var time: String
    var events: [String]
    var section: Int?
}

struct TimelineDiagram: Sendable {
    var title: String?
    var sections: [String] = []
    var periods: [TimelinePeriod] = []
    var down: Bool = false
}

enum TimelineParser {
    private static let colWidth: Float = 136.0
    private static let colGap: Float = 12.0
    private static let padX: Float = 10.0
    private static let padY: Float = 7.0

    static func parse(header: String, body: [String]) -> TimelineDiagram? {
        let h = header.trimmingCharacters(in: .whitespaces)
        var t = TimelineDiagram(down: h == "TD" || h == "TB")
        var items = 0
        for l in body {
            if let rest = word(l, "title") {
                let s = clean(rest)
                t.title = s.isEmpty ? nil : s
                continue
            }
            if let rest = word(l, "section") {
                t.sections.append(clean(rest))
                items += 1
                continue
            }
            if l.hasPrefix("accTitle") || l.hasPrefix("accDescr") {
                continue
            }
            var parts = l.split(separator: ":", omittingEmptySubsequences: false).map { clean(String($0)) }
            let time = parts.isEmpty ? "" : parts.removeFirst()
            let events = parts.filter { !$0.isEmpty }
            items += events.count + (time.isEmpty ? 0 : 1)
            if items > MermaidLimits.maxItems { return nil }
            if time.isEmpty {
                if !t.periods.isEmpty {
                    t.periods[t.periods.count - 1].events.append(contentsOf: events)
                }
                continue
            }
            let section = t.sections.isEmpty ? nil : (t.sections.count - 1)
            t.periods.append(TimelinePeriod(time: time, events: events, section: section))
        }
        return t.periods.isEmpty ? nil : t
    }

    private static func periodHue(_ t: TimelineDiagram, _ i: Int) -> Float {
        MermaidChart.hue(t.periods[i].section ?? i)
    }

    static func draw(_ t: TimelineDiagram, paint: MermaidTheme) -> MermaidScene? {
        let n = Float(t.periods.count)
        if t.down || n * colWidth + (n - 1.0) * colGap > Canvas.room(for: paint) / 0.75 {
            return drawDown(t, paint: paint)
        }
        let head = MermaidChart.bold(paint.font)
        let note = MermaidChart.small(paint)
        let inner = colWidth - 2.0 * padX
        let times = t.periods.map { measureWrap($0.time, font: head, maxWidth: inner) }
        let events = t.periods.map { p in p.events.map { measureWrap($0, font: note, maxWidth: inner) } }
        let titles = t.sections.map { measureWrap($0, font: head, maxWidth: 4.0 * colWidth) }

        func xOf(_ i: Int) -> Float { Float(i) * (colWidth + colGap) }

        var c = Canvas()
        var y: Float = 0.0
        if !t.sections.isEmpty {
            let band = (titles.map { $0.size.y }.max() ?? 0.0) + 2.0 * padY
            for (s, m) in titles.enumerated() {
                let cols = t.periods.indices.filter { t.periods[$0].section == s }
                guard let a = cols.first, let b = cols.last else { continue }
                let fill = MermaidChart.solid(paint, hue: MermaidChart.hue(s))
                c.fill(CanvasMath.roundedRect(x0: xOf(a), y0: 0.0, x1: xOf(b) + colWidth, y1: band, r: 6.0), color: fill)
                c.label(m, center: Vec2((xOf(a) + xOf(b) + colWidth) * 0.5, band * 0.5), font: head, color: MermaidChart.ink(fill), align: .center)
            }
            y = band + 10.0
        }

        let boxH = (times.map { $0.size.y }.max() ?? 0.0) + 2.0 * padY
        let lineY = y + boxH + 18.0
        for (i, m) in times.enumerated() {
            let h = periodHue(t, i)
            let x = xOf(i)
            var ey = lineY + 18.0
            let boxes: [(Float, Float)] = events[i].map { e in
                let top = ey
                let eh = e.size.y + 2.0 * padY
                ey += eh + 8.0
                return (top, eh)
            }
            let end = boxes.last.map { $0.0 + $0.1 * 0.5 } ?? lineY
            c.dashed([Vec2(x + colWidth * 0.5, y + boxH), Vec2(x + colWidth * 0.5, end)], width: 1.0, color: MermaidChart.strong(paint, hue: h).alpha(0.6), on: 4.0, off: 3.0)
            c.shape(CanvasMath.roundedRect(x0: x, y0: y, x1: x + colWidth, y1: y + boxH, r: 6.0), fill: MermaidChart.soft(paint, hue: h), border: MermaidChart.strong(paint, hue: h), width: 1.0)
            c.label(m, center: Vec2(x + colWidth * 0.5, y + boxH * 0.5), font: head, color: paint.text, align: .center)
            for (e, (top, eh)) in zip(events[i], boxes) {
                c.shape(CanvasMath.roundedRect(x0: x + 6.0, y0: top, x1: x + colWidth - 6.0, y1: top + eh, r: 5.0), fill: paint.nodeFill, border: MermaidChart.strong(paint, hue: h).alpha(0.55), width: 1.0)
                c.label(e, center: Vec2(x + colWidth * 0.5, top + eh * 0.5), font: note, color: paint.text, align: .center)
            }
        }
        let right = xOf(t.periods.count - 1) + colWidth + 14.0
        c.stroke([Vec2(-6.0, lineY), Vec2(right - 8.0, lineY)], closed: false, width: 2.0, color: paint.line)
        c.fill(CanvasMath.arrowhead(tip: Vec2(right, lineY), dir: Vec2(1.0, 0.0), len: 10.0, width: 9.0), color: paint.line)
        return c.finishFitMutating(paint: paint)
    }

    private static func drawDown(_ t: TimelineDiagram, paint: MermaidTheme) -> MermaidScene? {
        let head = MermaidChart.bold(paint.font)
        let note = MermaidChart.small(paint)
        let times = t.periods.map { measureWrap($0.time, font: head, maxWidth: 140.0) }
        let tw = times.map { $0.size.x }.max() ?? 0.0
        let spine = tw + 18.0
        let x0 = spine + 18.0
        let x1 = max(Canvas.room(for: paint), x0 + 160.0)

        var c = Canvas()
        var y: Float = 0.0
        var section: Int? = nil

        for (i, (p, m)) in zip(t.periods, times).enumerated() {
            if p.section != section, let s = p.section {
                section = s
                let title = measureWrap(t.sections[s], font: head, maxWidth: x1 - 2.0 * padX)
                let band = title.size.y + 2.0 * padY
                let fill = MermaidChart.solid(paint, hue: MermaidChart.hue(s))
                c.fill(CanvasMath.roundedRect(x0: 0.0, y0: y, x1: x1, y1: y + band, r: 6.0), color: fill)
                c.labelAt(title, at: Vec2(padX, y + padY), font: head, color: MermaidChart.ink(fill), align: .leading)
                y += band + 10.0
            }
            let h = periodHue(t, i)
            let chips = p.events.map { measureWrap($0, font: note, maxWidth: x1 - x0 - 2.0 * padX) }
            var at: [Vec2] = []
            var cx = x0
            var cy = y
            var rowH: Float = 0.0
            for chip in chips {
                let w = chip.size.x + 2.0 * padX
                if cx > x0 && cx + w > x1 {
                    cx = x0
                    cy += rowH + 6.0
                    rowH = 0.0
                }
                at.append(Vec2(cx, cy))
                cx += w + 6.0
                rowH = max(rowH, chip.size.y + 2.0 * padY)
            }
            let rowBottom = max(cy + rowH, y + m.size.y + 2.0 * padY)
            let mid = y + (m.size.y + 2.0 * padY) * 0.5
            c.labelAt(m, at: Vec2(spine - 14.0 - m.size.x, mid - m.size.y * 0.5), font: head, color: paint.text, align: .trailing)
            c.stroke([Vec2(spine, y - 5.0), Vec2(spine, rowBottom + 5.0)], closed: false, width: 2.0, color: paint.line)
            c.shape(CanvasMath.ellipse(center: Vec2(spine, mid), rx: 5.0, ry: 5.0), fill: MermaidChart.solid(paint, hue: h), border: paint.surface, width: 2.0)
            for (chip, a) in zip(chips, at) {
                let w = chip.size.x + 2.0 * padX
                let ch = chip.size.y + 2.0 * padY
                c.shape(CanvasMath.roundedRect(x0: a.x, y0: a.y, x1: a.x + w, y1: a.y + ch, r: 5.0), fill: MermaidChart.soft(paint, hue: h), border: MermaidChart.strong(paint, hue: h).alpha(0.6), width: 1.0)
                c.labelAt(chip, at: Vec2(a.x + padX, a.y + padY), font: note, color: paint.text, align: .leading)
            }
            y = rowBottom + 10.0
        }
        return c.finish(scale: 1.0, paint: paint)
    }
}
