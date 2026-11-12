import Foundation
import Rune

struct RequirementNode: Sendable {
    var name: String
    var kind: String
    var fields: [String]
    var style: NodeStyle
}

struct RequirementDiagram: Sendable {
    var dir: DiagramDirection
    var nodes: [RequirementNode]
    var edges: [LayeredEdge]
}

enum RequirementParser {
    private static let kinds: [(String, String)] = [
        ("requirement", "Requirement"),
        ("functionalRequirement", "Functional Requirement"),
        ("interfaceRequirement", "Interface Requirement"),
        ("performanceRequirement", "Performance Requirement"),
        ("physicalRequirement", "Physical Requirement"),
        ("designConstraint", "Design Constraint"),
        ("element", "Element"),
    ]

    private static let relations = [
        "contains", "copies", "derives", "satisfies", "verifies", "refines", "traces",
    ]

    private static let spacing = LayeredLayout.Spacing(node: 40.0, rank: 56.0, cluster: 16.0)

    static func parse(_ body: [String]) -> RequirementDiagram? {
        var d = RequirementDiagram(dir: .down, nodes: [], edges: [])
        var ids: [String: Int] = [:]
        var styles = StyleSheet()
        var open: Int? = nil

        func ensureNode(_ rawName: String) -> Int {
            let namePart: String
            let cls: String?
            if let colons = rawName.range(of: ":::") {
                namePart = String(rawName[..<colons.lowerBound])
                cls = String(rawName[colons.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                namePart = rawName
                cls = nil
            }
            let cleaned = cleanQuoted(namePart)
            let idx: Int
            if let existing = ids[cleaned] {
                idx = existing
            } else {
                idx = d.nodes.count
                d.nodes.append(RequirementNode(name: cleaned, kind: "", fields: [], style: .default))
                ids[cleaned] = idx
            }
            if let cls, !cls.isEmpty {
                styles.addClass(d.nodes[idx].name, cls)
            }
            return idx
        }

        for l in body {
            if let i = open {
                let closes = l.hasSuffix("}")
                let line = closes ? String(l.dropLast()).trimmingCharacters(in: .whitespaces) : l
                if let colon = line.firstIndex(of: ":") {
                    let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let v = cleanQuoted(String(line[line.index(after: colon)...]))
                    switch k {
                    case "id": d.nodes[i].fields.append("ID: \(v)")
                    case "text": d.nodes[i].fields.append("Text: \(v)")
                    case "risk": d.nodes[i].fields.append("Risk: \(titleCase(v))")
                    case "verifymethod": d.nodes[i].fields.append("Verification: \(titleCase(v))")
                    case "type": d.nodes[i].fields.append("Type: \(v)")
                    case "docref": d.nodes[i].fields.append("Doc Ref: \(v)")
                    default: break
                    }
                }
                if closes { open = nil }
                continue
            }

            if let rest = word(l, "direction") {
                d.dir = DiagramDirection.parse(rest) ?? d.dir
            } else if let rest = word(l, "classDef") {
                styles.classDef(rest)
            } else if let rest = word(l, "class") {
                if let ws = rest.firstIndex(where: \.isWhitespace) {
                    let names = rest[..<ws]
                    let cls = rest[ws...].trimmingCharacters(in: .whitespaces)
                    for n in names.split(separator: ",") {
                        styles.addClass(cleanQuoted(String(n)), cls)
                    }
                }
            } else if let rest = word(l, "style") {
                if let ws = rest.firstIndex(where: \.isWhitespace) {
                    let names = rest[..<ws]
                    let st = parseStyleProps(String(rest[ws...]))
                    for n in names.split(separator: ",") {
                        styles.addStyle(cleanQuoted(String(n)), st)
                    }
                }
            } else if let (kind, rest) = kinds.compactMap({ (w, k) in word(l, w).map { (k, $0) } }).first {
                let trimmed = rest.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasSuffix("{") else { continue }
                let name = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let i = ensureNode(name)
                d.nodes[i].kind = kind
                open = i
            } else if let (from, rel, to) = parseRelation(l) {
                let a = ensureNode(from)
                let b = ensureNode(to)
                let contains = rel == "contains"
                d.edges.append(LayeredEdge(
                    from: a,
                    to: b,
                    label: "«\(rel)»",
                    line: contains ? .solid : .dotted,
                    start: contains ? .contains : .none,
                    end: contains ? .none : .arrow,
                    minlen: 1,
                    style: .default,
                    onCluster: (nil, nil)
                ))
            }

            if d.nodes.count + d.edges.count > MermaidLimits.maxItems {
                return nil
            }
        }

        for (name, i) in ids {
            d.nodes[i].style = styles.get(name)
        }
        return d.nodes.isEmpty ? nil : d
    }

    private static func parseRelation(_ l: String) -> (String, String, String)? {
        let from: String
        let mid: String
        let to: String
        if let arrow = l.range(of: "->") {
            let left = String(l[..<arrow.lowerBound])
            guard let dash = left.lastIndex(of: "-") else { return nil }
            from = String(left[..<dash])
            mid = String(left[left.index(after: dash)...])
            to = String(l[arrow.upperBound...])
        } else if let arrow = l.range(of: "<-") {
            to = String(l[..<arrow.lowerBound])
            let right = String(l[arrow.upperBound...])
            guard let dash = right.firstIndex(of: "-") else { return nil }
            mid = String(right[..<dash])
            from = String(right[right.index(after: dash)...])
        } else {
            return nil
        }

        let trimmedMid = mid.trimmingCharacters(in: .whitespaces).lowercased()
        guard let rel = relations.first(where: { $0 == trimmedMid }) else { return nil }
        let f = from.trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty else { return nil }
        return (f, rel, t)
    }

    private static func titleCase(_ s: String) -> String {
        guard let first = s.first else { return "" }
        return first.uppercased() + s.dropFirst().lowercased()
    }

    static func draw(_ d: RequirementDiagram, paint: MermaidTheme, hover: (MermaidHover, Color)?) -> MermaidScene? {
        let nodes = d.nodes.map { r in
            LayeredDrawer.classBox(
                stereo: r.kind.isEmpty ? nil : r.kind,
                name: r.name,
                fields: r.fields,
                methods: [],
                cluster: nil,
                style: r.style,
                paint: paint
            )
        }
        return LayeredDrawer.drawLayered(dir: d.dir, nodes: nodes, edges: d.edges, clusters: [], spacing: spacing, paint: paint, hover: hover)
    }
}
