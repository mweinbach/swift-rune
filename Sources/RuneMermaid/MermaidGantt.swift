import Foundation
import Rune

struct GanttTags: Equatable, Sendable {
    var done = false
    var active = false
    var crit = false
    var milestone = false
    var vert = false
}

struct GanttTask: Sendable {
    var name: String
    var section: Int?
    var start: Double
    var end: Double
    var tags: GanttTags
}

struct GanttExcludes: Sendable {
    var weekdays: [Bool] = Array(repeating: false, count: 7)
    var days: Set<Int64> = []

    var any: Bool {
        weekdays.contains(true) || !days.isEmpty
    }

    func has(_ day: Int64) -> Bool {
        weekdays[Int(MermaidDate.remEuclid(day + 4, 7))] || days.contains(day)
    }
}

struct GanttDiagram: Sendable {
    var title: String?
    var sections: [String] = []
    var tasks: [GanttTask] = []
    var axis: String = "%Y-%m-%d"
    var tick: MermaidDate.Step? = nil
    var excludes: GanttExcludes = GanttExcludes()
}

enum GanttParser {
    private enum FromSpec {
        case prev
        case at(Double)
        case after([String])
    }

    private enum ToSpec {
        case at(Double)
        case span(MermaidDate.Span)
        case until([String])
    }

    private struct RawTask {
        var name: String
        var section: Int?
        var tags: GanttTags
        var id: String?
        var from: FromSpec
        var to: ToSpec
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let sectionHues: [Float] = [255.0, 150.0, 70.0, 305.0, 195.0, 110.0, 280.0, 225.0]
    private static let critHue: Float = 25.0
    private static let barHeight: Float = 22.0
    private static let rowPitch: Float = 28.0

    static func parse(header: String, body: [String]) -> GanttDiagram? {
        var g = GanttDiagram()
        var format = "YYYY-MM-DD"
        var raws: [RawTask] = []
        var inclusive = false
        var weekendFriday = false
        var weekends = false
        var lines: [String] = []

        for line in [header] + body {
            for stmt in statements(line) {
                let wordName: String
                let rest: String
                if let ws = stmt.firstIndex(where: \.isWhitespace) {
                    wordName = String(stmt[..<ws])
                    rest = String(stmt[ws...]).trimmingCharacters(in: .whitespaces)
                } else {
                    wordName = stmt
                    rest = ""
                }
                switch wordName {
                case "dateFormat" where !rest.isEmpty:
                    format = rest
                case "axisFormat" where !rest.isEmpty:
                    g.axis = rest
                case "tickInterval":
                    g.tick = MermaidDate.Step.parse(rest) ?? g.tick
                case "inclusiveEndDates":
                    inclusive = true
                case "weekend":
                    weekendFriday = rest.lowercased() == "friday"
                case "title":
                    let t = cleanQuoted(rest)
                    g.title = t.isEmpty ? nil : t
                case "excludes":
                    var hasDates = false
                    for part in rest.split(whereSeparator: { $0 == "," || $0 == " " }) {
                        let p = part.trimmingCharacters(in: .whitespaces)
                        if p.isEmpty { continue }
                        let lp = p.lowercased()
                        if lp == "weekends" {
                            weekends = true
                        } else if let wd = weekdays.firstIndex(of: lp) {
                            g.excludes.weekdays[wd] = true
                        } else {
                            hasDates = true
                        }
                    }
                    if hasDates { lines.append(stmt) }
                case "includes", "todayMarker", "topAxis", "weekday", "displayMode", "click", "accTitle", "accDescr":
                    break
                default:
                    lines.append(stmt)
                }
            }
        }

        if weekends {
            let (a, b) = weekendFriday ? (5, 6) : (6, 0)
            g.excludes.weekdays[a] = true
            g.excludes.weekdays[b] = true
        }

        for stmt in lines {
            if stmt.hasPrefix("excludes") {
                let rest = String(stmt.dropFirst("excludes".count))
                for part in rest.split(whereSeparator: { $0 == "," || $0 == " " }) {
                    let p = part.trimmingCharacters(in: .whitespaces)
                    if !p.isEmpty, let t = MermaidDate.parse(p, format: format) {
                        g.excludes.days.insert(Int64(floor(t / MermaidDate.day)))
                    }
                }
                continue
            }
            if stmt.hasPrefix("section") {
                let rest = String(stmt.dropFirst("section".count))
                if g.sections.count + raws.count >= MermaidLimits.maxItems { return nil }
                g.sections.append(clean(rest))
                continue
            }
            guard let colon = stmt.firstIndex(of: ":") else { continue }
            let name = String(stmt[..<colon])
            let meta = String(stmt[stmt.index(after: colon)...])
            let section = g.sections.isEmpty ? nil : (g.sections.count - 1)
            if let r = parseTask(name: clean(name), section: section, meta: meta, format: format, inclusive: inclusive) {
                if g.sections.count + raws.count >= MermaidLimits.maxItems { return nil }
                raws.append(r)
            }
        }

        g.tasks = resolve(raws, excludes: g.excludes)
        return g.tasks.isEmpty ? nil : g
    }

    private static func parseTask(
        name: String,
        section: Int?,
        meta: String,
        format: String,
        inclusive: Bool
    ) -> RawTask? {
        var parts = meta.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var tags = GanttTags()
        while let first = parts.first {
            switch first {
            case "done": tags.done = true
            case "active": tags.active = true
            case "crit": tags.crit = true
            case "milestone": tags.milestone = true
            case "vert": tags.vert = true
            default: break
            }
            if first == "done" || first == "active" || first == "crit" || first == "milestone" || first == "vert" {
                parts.removeFirst()
            } else {
                break
            }
        }

        let id: String?
        let from: FromSpec
        let toStr: String
        switch parts.count {
        case 1:
            id = nil
            from = .prev
            toStr = parts[0]
        case 2:
            guard let f = parseFrom(parts[0], format: format) else { return nil }
            id = nil
            from = f
            toStr = parts[1]
        case 3:
            guard let f = parseFrom(parts[1], format: format) else { return nil }
            id = parts[0].isEmpty ? nil : parts[0]
            from = f
            toStr = parts[2]
        default:
            return nil
        }

        let to: ToSpec
        if toStr.hasPrefix("until ") {
            let ids = String(toStr.dropFirst("until ".count)).split(whereSeparator: \.isWhitespace).map(String.init)
            to = .until(ids)
        } else if let s = MermaidDate.parseSpan(toStr) {
            to = .span(s)
        } else if let t = MermaidDate.parse(toStr, format: format) {
            to = .at(t + (inclusive ? MermaidDate.day : 0.0))
        } else {
            return nil
        }

        return RawTask(name: name, section: section, tags: tags, id: id, from: from, to: to)
    }

    private static func parseFrom(_ s: String, format: String) -> FromSpec? {
        if s.hasPrefix("after ") {
            let ids = String(s.dropFirst("after ".count)).split(whereSeparator: \.isWhitespace).map(String.init)
            return .after(ids)
        }
        return MermaidDate.parse(s, format: format).map(FromSpec.at)
    }

    private static func resolve(_ raws: [RawTask], excludes: GanttExcludes) -> [GanttTask] {
        var ids: [String: Int] = [:]
        for (i, r) in raws.enumerated() {
            if let id = r.id { ids[id] = i }
        }
        var times: [(Double, Double)?] = Array(repeating: nil, count: raws.count)
        for _ in 0...raws.count {
            var changed = false
            for (i, r) in raws.enumerated() {
                if times[i] != nil { continue }
                func linked(_ names: [String], pick: ((Double, Double)) -> Double, best: (Double, Double) -> Double) -> Double? {
                    let known = names.compactMap { ids[$0] }
                    let got = known.compactMap { k in times[k].map(pick) }
                    guard !known.isEmpty, got.count == known.count else { return nil }
                    return got.dropFirst().reduce(got[0], best)
                }

                let start: Double?
                switch r.from {
                case let .at(t):
                    start = t
                case .prev:
                    start = i > 0 ? times[i - 1]?.1 : nil
                case let .after(names):
                    start = linked(names, pick: { $0.1 }, best: max)
                }
                guard let s = start else { continue }

                let end: Double?
                switch r.to {
                case let .at(t):
                    end = t
                case let .span(sp):
                    end = skipExcluded(start: s, end: sp.after(s), excludes: excludes)
                case let .until(names):
                    end = linked(names, pick: { $0.0 }, best: min)
                }
                if let e = end {
                    times[i] = (s, max(e, s))
                    changed = true
                }
            }
            if !changed { break }
        }

        return zip(raws, times).compactMap { r, t in
            guard let (s, e) = t else { return nil }
            return GanttTask(name: r.name, section: r.section, start: s, end: e, tags: r.tags)
        }
    }

    private static func skipExcluded(start: Double, end initialEnd: Double, excludes: GanttExcludes) -> Double {
        if !excludes.any { return initialEnd }
        var end = initialEnd
        var day = Int64(floor(start / MermaidDate.day))
        for _ in 0..<3660 {
            if Double(day) * MermaidDate.day >= end { break }
            if excludes.has(day) { end += MermaidDate.day }
            day += 1
        }
        return end
    }

    private static func sectionHue(_ s: Int) -> Float {
        sectionHues[s % sectionHues.count]
    }

    static func draw(_ g: GanttDiagram, paint: MermaidTheme) -> MermaidScene? {
        let small = MermaidChart.small(paint)
        let bold = MermaidChart.bold(small)
        let w = Canvas.room(for: paint)
        let rows = g.tasks.filter { !$0.tags.vert }
        let marks = g.tasks.filter { $0.tags.vert }

        var used: [Int] = []
        for t in rows {
            if let s = t.section, used.last != s {
                used.append(s)
            }
        }
        let side = (w * 0.28).rounded(.down)
        let titles = g.sections.map { measureWrap($0, font: bold, maxWidth: max(side - 16.0, 1.0)) }
        let left = min(used.map { titles[$0].size.x + 16.0 }.max() ?? 0.0, side)
        let x0 = left + 4.0
        let x1 = w - 4.0
        let lo = g.tasks.map(\.start).min() ?? 0.0
        var hi = g.tasks.map(\.end).max() ?? 0.0
        if hi - lo < 1.0 { hi = lo + MermaidDate.day }

        func sx(_ t: Double) -> Float {
            x0 + Float((t - lo) / (hi - lo)) * (x1 - x0)
        }

        let markLabels = marks.map { measureText($0.name, font: small) }
        let top = markLabels.map { $0.size.y + 6.0 }.max() ?? 0.0
        let bottom = top + Float(rows.count) * rowPitch + 4.0
        var c = Canvas()

        var r0 = 0
        while r0 < rows.count {
            let sec = rows[r0].section
            var r1 = r0 + 1
            while r1 < rows.count && rows[r1].section == sec { r1 += 1 }
            let y0 = top + Float(r0) * rowPitch
            let y1 = top + Float(r1) * rowPitch + (r1 == rows.count ? 4.0 : 0.0)
            if let s = sec {
                c.fill([Vec2(0.0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(0.0, y1)], color: MermaidChart.strong(paint, hue: sectionHue(s)).alpha(0.07))
                c.label(titles[s], center: Vec2(left * 0.5, (y0 + y1) * 0.5), font: bold, color: paint.text, align: .center)
            }
            r0 = r1
        }

        let d0 = Int64(floor(lo / MermaidDate.day))
        let d1 = Int64(ceil(hi / MermaidDate.day))
        if g.excludes.any && d1 - d0 <= 400 {
            for day in d0..<d1 where g.excludes.has(day) {
                let a = max(sx(Double(day) * MermaidDate.day), x0)
                let b = min(sx(Double(day + 1) * MermaidDate.day), x1)
                c.fill([Vec2(a, top), Vec2(b, top), Vec2(b, bottom), Vec2(a, bottom)], color: paint.text.alpha(0.05))
            }
        }

        let probe = measureText(MermaidDate.format(lo, fmt: g.axis), font: small).size.x + 16.0
        let step = g.tick ?? MermaidDate.Step.ladder.first(where: { s in
            let px = s.length / (hi - lo) * Double(x1 - x0)
            return px >= Double(probe) && (hi - lo) / s.length <= 40.0
        }) ?? .months(60)
        let ticks = step.ticks(lo: lo, hi: hi, max: 200).map { t in
            (sx(t), measureText(MermaidDate.format(t, fmt: g.axis), font: small))
        }
        MermaidChart.axisX(&c, ticks: ticks, xRange: (x0, x1), yRange: (top, bottom), font: small, paint: paint)

        for (t, m) in zip(marks, markLabels) {
            let x = sx(t.start)
            let color = t.tags.crit ? MermaidChart.strong(paint, hue: critHue) : paint.muted
            c.dashed([Vec2(x, top - 2.0), Vec2(x, bottom)], width: 1.25, color: color, on: 4.0, off: 3.0)
            let lx = min(max(x - m.size.x * 0.5, 0.0), max(x1 - m.size.x, 0.0))
            c.labelAt(m, at: Vec2(lx, 0.0), font: small, color: color, align: .leading)
        }

        for (r, t) in rows.enumerated() {
            let y = top + Float(r) * rowPitch + (rowPitch - barHeight) * 0.5 + 2.0
            let h = t.tags.crit ? critHue : sectionHue(t.section ?? 0)
            var fill = MermaidChart.soft(paint, hue: h)
            var border = MermaidChart.strong(paint, hue: h)
            var width: Float = 1.0
            if t.tags.active {
                fill = oklabMix(fill, paint.surface, 0.55)
                width = 1.5
            }
            if t.tags.done {
                fill = overColor(paint.text.alpha(0.12), paint.surface)
                if !t.tags.crit { border = paint.nodeBorder }
            }
            let m = measureText(t.name, font: small)
            let a = sx(t.start)
            let b = max(sx(t.end), a + 2.0)
            let mid = y + barHeight * 0.5
            if t.tags.milestone {
                let rad = barHeight * 0.5
                c.shape([Vec2(a, mid - rad), Vec2(a + rad, mid), Vec2(a, mid + rad), Vec2(a - rad, mid)], fill: fill, border: border, width: width)
                let lx = (a + rad + 6.0 + m.size.x <= x1) ? (a + rad + 6.0) : max(a - rad - 6.0 - m.size.x, 0.0)
                c.labelAt(m, at: Vec2(lx, mid - m.size.y * 0.5), font: small, color: paint.text, align: .leading)
                continue
            }
            c.shape(CanvasMath.roundedRect(x0: a, y0: y, x1: b, y1: y + barHeight, r: 3.0), fill: fill, border: border, width: width)
            let (lx, lcol): (Float, Color)
            if m.size.x + 12.0 <= b - a {
                lx = (a + b - m.size.x) * 0.5
                lcol = MermaidChart.ink(fill)
            } else if b + 6.0 + m.size.x <= x1 {
                lx = b + 6.0
                lcol = paint.text
            } else {
                lx = max(a - 6.0 - m.size.x, 0.0)
                lcol = paint.text
            }
            c.labelAt(m, at: Vec2(lx, mid - m.size.y * 0.5), font: small, color: lcol, align: .leading)
        }
        return c.finishFitMutating(paint: paint)
    }
}
