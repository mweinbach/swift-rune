import Foundation
import Rune

struct C4Diagram: Sendable {
    enum Base: Equatable, Sendable {
        case person
        case system
        case container
        case component
    }

    enum Store: Equatable, Sendable {
        case plain
        case db
        case queue
    }

    struct Element: Sendable {
        var base: Base
        var store: Store
        var external: Bool
        var label: String
        var techn: String
        var descr: String
        var boundary: Int?
    }

    struct Boundary: Sendable {
        var title: String
        var parent: Int?
    }

    var title: String?
    var elements: [Element] = []
    var boundaries: [Boundary] = []
    var edges: [LayeredEdge] = []
}

enum C4Parser {
    private enum Way {
        case down
        case up
        case back
    }

    private struct Rel {
        var from: String
        var to: String
        var label: String
        var techn: String
        var both: Bool
        var way: Way
    }

    private static let spacing = LayeredLayout.Spacing(node: 44.0, rank: 64.0, cluster: 20.0)

    static func parse(header: String, body: [String]) -> C4Diagram? {
        let dynamic = header == "C4Dynamic"
        var d = C4Diagram()
        var ids: [String: Int] = [:]
        var rels: [Rel] = []
        var stack: [Int] = []

        for l in body {
            if l.hasPrefix("}") {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            if let rest = word(l, "title") {
                let t = cleanQuoted(rest)
                d.title = t.isEmpty ? nil : t
                continue
            }
            guard let open = l.firstIndex(of: "("),
                  let close = l.lastIndex(of: ")"),
                  open < close else { continue }
            let name = String(l[..<open]).trimmingCharacters(in: .whitespaces)
            let (args, named) = parseArgs(String(l[l.index(after: open)..<close]))
            func arg(_ i: Int) -> String { i < args.count ? args[i] : "" }

            if let kind = parseBoundary(name) {
                if stack.count >= MermaidLimits.maxDepth { return nil }
                let ty: String?
                if args.count > 2 && !args[2].isEmpty {
                    ty = args[2]
                } else {
                    ty = kind
                }
                let label = (args.count > 1 ? args[1] : args.first) ?? ""
                let title = ty.map { "\(label)\n[\($0)]" } ?? label
                d.boundaries.append(C4Diagram.Boundary(title: title, parent: stack.last))
                if l[l.index(after: close)...].drop(while: \.isWhitespace).hasPrefix("{") {
                    stack.append(d.boundaries.count - 1)
                }
            } else if let (base, store, external) = parseElement(name) {
                guard let alias = args.first, !alias.isEmpty else { continue }
                var (techn, descr) = (base == .container || base == .component) ? (arg(2), arg(3)) : ("", arg(2))
                techn = named["techn"] ?? techn
                descr = named["descr"] ?? descr
                ids[alias] = d.elements.count
                d.elements.append(C4Diagram.Element(
                    base: base,
                    store: store,
                    external: external,
                    label: arg(1),
                    techn: techn,
                    descr: descr,
                    boundary: stack.last
                ))
            } else if let (both, way, indexed) = parseRelation(name) {
                let a = indexed ? Array(args.dropFirst()) : args
                func get(_ i: Int) -> String { i < a.count ? a[i] : "" }
                let techn = named["techn"] ?? get(3)
                rels.append(Rel(from: get(0), to: get(1), label: get(2), techn: techn, both: both, way: way))
            }

            if d.elements.count + d.boundaries.count + rels.count > MermaidLimits.maxItems {
                return nil
            }
        }

        var n = 0
        for r in rels {
            guard let a = ids[r.from], let b = ids[r.to] else { continue }
            n += 1
            var label = dynamic ? "\(n): \(r.label)" : r.label
            if !r.techn.isEmpty {
                label = "\(label)\n[\(r.techn)]"
            }
            let other: EdgeHead = r.both ? .arrow : .none
            let (from, to, start, end): (Int, Int, EdgeHead, EdgeHead)
            switch r.way {
            case .down: (from, to, start, end) = (a, b, other, .arrow)
            case .up: (from, to, start, end) = (b, a, .arrow, other)
            case .back: (from, to, start, end) = (a, b, .arrow, other)
            }
            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label
            d.edges.append(LayeredEdge(
                from: from,
                to: to,
                label: cleanLabel,
                line: .solid,
                start: start,
                end: end,
                minlen: 1,
                style: .default,
                onCluster: (nil, nil)
            ))
        }
        return d.elements.isEmpty ? nil : d
    }

    private static func parseArgs(_ s: String) -> ([String], [String: String]) {
        var parts: [String] = []
        var cur = ""
        var quoted = false
        for ch in s {
            if ch == "\"" {
                quoted.toggle()
                cur.append(ch)
            } else if ch == "," && !quoted {
                parts.append(cur)
                cur.removeAll(keepingCapacity: true)
            } else {
                cur.append(ch)
            }
        }
        parts.append(cur)

        var pos: [String] = []
        var named: [String: String] = [:]
        for raw in parts {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("$"), let eq = p.firstIndex(of: "=") {
                let k = String(p[p.index(after: p.startIndex)..<eq]).trimmingCharacters(in: .whitespaces)
                let v = cleanQuoted(String(p[p.index(after: eq)...]))
                named[k] = v
            } else if !p.hasPrefix("$") {
                pos.append(cleanQuoted(p))
            }
        }
        return (pos, named)
    }

    private static func parseBoundary(_ name: String) -> String?? {
        switch name {
        case "Boundary", "Deployment_Node", "Node", "Node_L", "Node_R":
            return .some(nil)
        case "Enterprise_Boundary":
            return .some("Enterprise")
        case "System_Boundary":
            return .some("System")
        case "Container_Boundary":
            return .some("Container")
        default:
            return nil
        }
    }

    private static func parseElement(_ rawName: String) -> (C4Diagram.Base, C4Diagram.Store, Bool)? {
        let external = rawName.hasSuffix("_Ext")
        let name = external ? String(rawName.dropLast("_Ext".count)) : rawName
        let prefixes: [(String, C4Diagram.Base)] = [
            ("Person", .person),
            ("System", .system),
            ("Container", .container),
            ("Component", .component),
        ]
        guard let (prefix, base) = prefixes.first(where: { name.hasPrefix($0.0) }) else { return nil }
        let rest = String(name.dropFirst(prefix.count))
        let store: C4Diagram.Store
        switch rest {
        case "": store = .plain
        case "Db" where base != .person: store = .db
        case "Queue" where base != .person: store = .queue
        default: return nil
        }
        return (base, store, external)
    }

    private static func parseRelation(_ name: String) -> (Bool, Way, Bool)? {
        let both: Bool
        let rest: String
        if name.hasPrefix("BiRel") {
            both = true
            rest = String(name.dropFirst("BiRel".count))
        } else if name.hasPrefix("Rel") {
            both = false
            rest = String(name.dropFirst("Rel".count))
        } else {
            return nil
        }
        switch rest {
        case "Index": return (both, .down, true)
        case "_Back": return (both, .back, false)
        case "_U", "_Up": return (both, .up, false)
        case "", "_D", "_Down", "_L", "_Left", "_R", "_Right", "_Neighbor": return (both, .down, false)
        default: return nil
        }
    }

    private static func stereotype(_ e: C4Diagram.Element) -> String {
        let base: String
        switch e.base {
        case .person: base = "person"
        case .system: base = "system"
        case .container: base = "container"
        case .component: base = "component"
        }
        let store: String
        switch e.store {
        case .plain: store = ""
        case .db: store = "_db"
        case .queue: store = "_queue"
        }
        return "«\(e.external ? "external_" : "")\(base)\(store)»"
    }

    private static func fill(_ e: C4Diagram.Element) -> Color {
        let l: Float
        switch (e.base, e.external) {
        case (.person, true): l = 0.46
        case (_, true): l = 0.64
        case (.person, false): l = 0.36
        case (.system, false): l = 0.48
        case (.container, false): l = 0.60
        case (.component, false): l = 0.76
        }
        return e.external ? oklch(l, 0.0, 0.0) : oklch(l, 0.11 - (l - 0.36) * 0.12, 252.0)
    }

    static func draw(_ d: C4Diagram, paint: MermaidTheme, hover: (MermaidHover, Color)?) -> MermaidScene? {
        let note = MermaidChart.small(paint)
        var stereoFont = note
        stereoFont.italic = true
        let headFont = MermaidChart.bold(paint.font)

        let nodes: [DrawNode] = d.elements.map { e in
            let techn = e.techn.isEmpty ? "" : "[\(e.techn)]"
            let rawLines: [(String, TextStyle)] = [
                (stereotype(e), stereoFont),
                (e.label, headFont),
                (techn, stereoFont),
                (e.descr, note),
            ]
            let lines = rawLines.filter { !$0.0.isEmpty }.map { (measureWrap($0.0, font: $0.1, maxWidth: 190.0), $0.1) }
            let shape: NodeShape
            switch e.store {
            case .plain: shape = .round
            case .db: shape = .cylinder
            case .queue: shape = .hCylinder
            }
            let maxLineW = lines.map(\.0.size.x).max() ?? 0.0
            let w = max(maxLineW + (shape == .hCylinder ? 52.0 : 32.0), 150.0)
            let person = e.base == .person
            var h = lines.reduce(Float(0.0)) { $0 + $1.0.size.y + 3.0 } + 22.0 + (person ? LayeredDrawer.personHeight : 0.0)
            if shape == .cylinder {
                h += 3.0 * ShapeRenderer.rim(w)
            }
            let f = fill(e)
            let border = oklch(max(f.toOKLab()[0] - 0.1, 0.2), 0.06, 252.0)
            return .card(
                shape: shape,
                lines: lines,
                size: Vec2(w, max(h, 64.0)),
                cluster: e.boundary,
                colors: (f, border, MermaidChart.ink(f)),
                person: person
            )
        }
        let clusters = d.boundaries.map { ClusterSpec(title: $0.title, parent: $0.parent) }
        return LayeredDrawer.drawLayered(dir: .down, nodes: nodes, edges: d.edges, clusters: clusters, spacing: spacing, paint: paint, hover: hover)
    }
}
