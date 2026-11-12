import Foundation
import Rune

struct QuadrantLook: Equatable, Sendable {
    var radius: Float?
    var color: Color?
    var stroke: Color?
    var strokeWidth: Float?

    func merged(over base: QuadrantLook) -> QuadrantLook {
        QuadrantLook(
            radius: radius ?? base.radius,
            color: color ?? base.color,
            stroke: stroke ?? base.stroke,
            strokeWidth: strokeWidth ?? base.strokeWidth
        )
    }
}

struct QuadrantPoint: Equatable, Sendable {
    var name: String
    var at: Vec2
    var look: QuadrantLook
}

struct QuadrantDiagram: Sendable {
    var title: String?
    var x: [String] = ["", ""]
    var y: [String] = ["", ""]
    var names: [String] = ["", "", "", ""]
    var points: [QuadrantPoint] = []
}

enum QuadrantParser {
    private static let hue: Float = 255.0

    static func parse(_ body: [String]) -> QuadrantDiagram? {
        var q = QuadrantDiagram()
        var classes: [String: QuadrantLook] = [:]
        var pending: [(String, Vec2, QuadrantLook, String?)] = []
        var any = false

        func splitAxis(_ rest: String) -> [String] {
            if let arrow = rest.range(of: "-->") {
                return [clean(String(rest[..<arrow.lowerBound])), clean(String(rest[arrow.upperBound...]))]
            }
            return [clean(rest), ""]
        }

        for l in body {
            if let rest = word(l, "title") {
                let t = clean(rest)
                q.title = t.isEmpty ? nil : t
            } else if let rest = word(l, "x-axis") {
                q.x = splitAxis(rest)
                any = true
            } else if let rest = word(l, "y-axis") {
                q.y = splitAxis(rest)
                any = true
            } else if l.hasPrefix("quadrant-"),
                      let ws = l.firstIndex(where: \.isWhitespace) {
                let numStr = String(l[l.index(l.startIndex, offsetBy: "quadrant-".count)..<ws])
                let rest = String(l[ws...])
                if let n = Int(numStr), (1...4).contains(n) {
                    q.names[n - 1] = clean(rest)
                    any = true
                }
            } else if let rest = word(l, "classDef") {
                let trimmed = rest.trimmingCharacters(in: .whitespaces)
                if let ws = trimmed.firstIndex(where: \.isWhitespace) {
                    let name = String(trimmed[..<ws])
                    let props = String(trimmed[ws...])
                    classes[name] = parseLook(props)
                } else if !trimmed.isEmpty {
                    classes[trimmed] = QuadrantLook()
                }
            } else if let p = parsePoint(l) {
                if pending.count >= MermaidLimits.maxItems { return nil }
                pending.append(p)
            }
        }

        q.points = pending.map { name, at, look, cls in
            let base = cls.flatMap { classes[$0] } ?? QuadrantLook()
            return QuadrantPoint(name: name, at: at, look: look.merged(over: base))
        }
        return (any || !q.points.isEmpty) ? q : nil
    }

    private static func parsePoint(_ l: String) -> (String, Vec2, QuadrantLook, String?)? {
        guard let open = l.firstIndex(of: "["),
              let close = l[open...].firstIndex(of: "]") else { return nil }
        let headTrimmed = l[..<open].trimmingCharacters(in: .whitespaces)
        guard headTrimmed.hasSuffix(":") else { return nil }
        let head = String(headTrimmed.dropLast())

        let name: String
        let cls: String?
        if let colons = head.range(of: ":::") {
            name = String(head[..<colons.lowerBound])
            cls = String(head[colons.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            name = head
            cls = nil
        }

        let coords = l[l.index(after: open)..<close]
        guard let comma = coords.firstIndex(of: ",") else { return nil }
        guard let x = Float(coords[..<comma].trimmingCharacters(in: .whitespaces)),
              let y = Float(coords[coords.index(after: comma)...].trimmingCharacters(in: .whitespaces)),
              x.isFinite, y.isFinite else { return nil }

        let cleanedName = clean(name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        let clamped = Vec2(min(max(x, 0.0), 1.0), min(max(y, 0.0), 1.0))
        let rest = String(l[l.index(after: close)...])
        return (cleanedName, clamped, parseLook(rest), cls)
    }

    private static func parseLook(_ props: String) -> QuadrantLook {
        var out = QuadrantLook()
        for part in props.split(separator: ",") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let k = part[..<colon].trimmingCharacters(in: .whitespaces)
            let v = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            func px() -> Float? {
                let s = v.hasSuffix("px") ? String(v.dropLast(2)).trimmingCharacters(in: .whitespaces) : v
                guard let f = Float(s), f.isFinite else { return nil }
                return f
            }
            switch k {
            case "radius":
                out.radius = px().map { min(max($0, 1.0), 30.0) }
            case "color":
                out.color = parseColorSpec(v)
            case "stroke-color":
                out.stroke = parseColorSpec(v)
            case "stroke-width":
                out.strokeWidth = px().map { min(max($0, 0.0), 8.0) }
            default:
                break
            }
        }
        return out
    }

    static func draw(_ q: QuadrantDiagram, paint: MermaidTheme) -> MermaidScene? {
        let note = MermaidChart.small(paint)
        let head = MermaidChart.bold(paint.font)
        let ys = q.y.map { measureWrap($0, font: note, maxWidth: 96.0) }
        let yw = ys.map { $0.size.x }.max() ?? 0.0
        let x0: Float = yw > 0.0 ? yw + 12.0 : 0.0
        let side = min(max(Canvas.room(for: paint) - x0, 220.0), 440.0)
        let half = side * 0.5
        let x1 = x0 + side
        let y1 = side

        var c = Canvas()
        // 1 top right, 2 top left, 3 bottom left, 4 bottom right.
        let origins: [Vec2] = [
            Vec2(x0 + half, 0.0),
            Vec2(x0, 0.0),
            Vec2(x0, half),
            Vec2(x0 + half, half),
        ]
        let tints: [Float] = [0.95, 0.7, 0.45, 0.7]
        for (o, a) in zip(origins, tints) {
            let fill = overColor(MermaidChart.soft(paint, hue: hue).alpha(a), paint.surface)
            c.fill([o, Vec2(o.x + half, o.y), Vec2(o.x + half, o.y + half), Vec2(o.x, o.y + half)], color: fill)
        }
        c.stroke([Vec2(x0 + half, 0.0), Vec2(x0 + half, y1)], closed: false, width: 2.0, color: paint.surface)
        c.stroke([Vec2(x0, half), Vec2(x1, half)], closed: false, width: 2.0, color: paint.surface)

        for (o, name) in zip(origins, q.names) {
            let m = measureWrap(name, font: head, maxWidth: half - 16.0)
            let y = q.points.isEmpty ? o.y + half * 0.5 : o.y + 10.0 + m.size.y * 0.5
            c.label(m, center: Vec2(o.x + half * 0.5, y), font: head, color: paint.text, align: .center)
        }

        let xs = q.x.map { measureWrap($0, font: note, maxWidth: half - 8.0) }
        let below = y1 + 8.0
        if xs[1].text.isEmpty {
            c.labelAt(xs[0], at: Vec2(x0 + half - xs[0].size.x * 0.5, below), font: note, color: paint.muted, align: .center)
        } else {
            for (i, m) in xs.enumerated() {
                c.labelAt(m, at: Vec2(x0 + half * (Float(i) + 0.5) - m.size.x * 0.5, below), font: note, color: paint.muted, align: .center)
            }
        }

        if ys[1].text.isEmpty {
            c.labelAt(ys[0], at: Vec2(x0 - 12.0 - ys[0].size.x, half - ys[0].size.y * 0.5), font: note, color: paint.muted, align: .trailing)
        } else {
            for (i, m) in ys.enumerated() {
                let mid = i == 0 ? half * 1.5 : half * 0.5
                c.labelAt(m, at: Vec2(x0 - 12.0 - m.size.x, mid - m.size.y * 0.5), font: note, color: paint.muted, align: .trailing)
            }
        }

        for p in q.points {
            let at = Vec2(x0 + p.at.x * side, y1 - p.at.y * side)
            let r = p.look.radius ?? 5.0
            let fill = p.look.color ?? MermaidChart.strong(paint, hue: hue)
            let width = p.look.strokeWidth ?? (p.look.stroke != nil ? 2.0 : 0.0)
            c.fill(CanvasMath.ellipse(center: at, rx: r, ry: r), color: fill)
            if width > 0.0 {
                c.stroke(CanvasMath.ellipse(center: at, rx: r, ry: r), closed: true, width: width, color: p.look.stroke ?? fill)
            }
            let m = measureText(p.name, font: note)
            c.labelAt(m, at: Vec2(at.x - m.size.x * 0.5, at.y + r + 3.0), font: note, color: paint.text, align: .center)
        }
        return c.finishFitMutating(paint: paint)
    }
}
