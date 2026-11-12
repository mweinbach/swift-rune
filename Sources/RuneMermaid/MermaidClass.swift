import Foundation
import Rune

// MARK: - Class Diagram AST & Parser

struct ClassNode: Equatable {
    var id: String
    var label: String
    var stereo: String?
    var fields: [String] = []
    var methods: [String] = []
    var namespace: Int?
    var style: NodeStyle = .default
}

struct ClassNamespace: Equatable {
    var title: String
}

struct ClassDiagram {
    var title: String?
    var dir: DiagramDirection = .down
    var classes: [ClassNode] = []
    var edges: [LayeredEdge] = []
    var namespaces: [ClassNamespace] = []
}

enum ClassParser {
    private static let rels: [(tok: String, start: EdgeHead, end: EdgeHead, line: EdgeLine)] = [
        ("<|..", .openTriangle, .none, .dotted),
        ("..|>", .none, .openTriangle, .dotted),
        ("<|--", .openTriangle, .none, .solid),
        ("--|>", .none, .openTriangle, .solid),
        ("*--", .diamondFilled, .none, .solid),
        ("--*", .none, .diamondFilled, .solid),
        ("o--", .diamondOpen, .none, .solid),
        ("--o", .none, .diamondOpen, .solid),
        ("<-->", .arrow, .arrow, .solid),
        ("<..>", .arrow, .arrow, .dotted),
        ("-->", .none, .arrow, .solid),
        ("<--", .arrow, .none, .solid),
        ("..>", .none, .arrow, .dotted),
        ("<..", .arrow, .none, .dotted),
        ("--", .none, .none, .solid),
        ("..", .none, .none, .dotted),
    ]

    private struct Parser: LenientParser {
        struct Mark {
            let classes: Int
            let edges: Int
        }

        var d = ClassDiagram()
        var ids: [String: Int] = [:]
        var activeClass: Int?
        var activeNs: Int?
        var styles = StyleSheet()
        var members = 0
        var isOver = false

        func mark() -> Mark {
            Mark(classes: d.classes.count, edges: d.edges.count)
        }

        mutating func undo(_ mark: Mark) {
            if d.classes.count > mark.classes {
                d.classes.removeSubrange(mark.classes...)
            }
            if d.edges.count > mark.edges {
                d.edges.removeSubrange(mark.edges...)
            }
            ids = ids.filter { $0.value < mark.classes }
        }

        func isOverLimit() -> Bool { isOver }

        mutating func readStatement(_ s: String) -> Bool {
            statement(s)
        }

        mutating func budget() -> Bool {
            if d.classes.count + d.edges.count + d.namespaces.count >= MermaidLimits.maxItems {
                isOver = true
            }
            return !isOver
        }

        mutating func statement(_ s: String) -> Bool {
            if let idx = activeClass {
                if s == "}" {
                    activeClass = nil
                    return true
                }
                addMember(idx, s)
                return !isOver
            }
            if s == "}" {
                guard activeNs != nil else { return false }
                activeNs = nil
                return true
            }
            let firstWord = s.split(maxSplits: 1, whereSeparator: { $0.isWhitespace || $0 == ":" }).first.map(String.init) ?? ""
            switch firstWord {
            case "title":
                let t = cleanQuoted(String(s.dropFirst("title".count)).trimmingCharacters(in: .whitespaces))
                if !t.isEmpty { d.title = t }
                return true
            case "direction":
                let dirStr = String(s.dropFirst("direction".count)).trimmingCharacters(in: .whitespaces)
                guard let parsed = DiagramDirection.parse(dirStr) else { return false }
                if d.edges.isEmpty { d.dir = parsed }
                return true
            case "namespace":
                guard activeNs == nil else { return false }
                let rest = String(s.dropFirst("namespace".count)).trimmingCharacters(in: .whitespaces)
                guard rest.hasSuffix("{") else { return false }
                let title = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
                guard budget() else { return false }
                d.namespaces.append(ClassNamespace(title: cleanQuoted(title)))
                activeNs = d.namespaces.count - 1
                return true
            case "class":
                return classDecl(String(s.dropFirst("class".count)).trimmingCharacters(in: .whitespaces))
            case "note", "Note", "link", "click", "callback", "accTitle", "accDescr":
                return true
            case "classDef":
                _ = styles.classDef(String(s.dropFirst("classDef".count)))
                return true
            case "cssClass":
                let rest = String(s.dropFirst("cssClass".count)).trimmingCharacters(in: .whitespaces)
                if let ws = rest.lastIndex(where: \.isWhitespace) {
                    let targets = rest[..<ws].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    let cls = rest[ws...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    for id in targets.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        styles.addClass(id, cls)
                    }
                }
                return true
            case "style":
                _ = styles.style(String(s.dropFirst("style".count)))
                return true
            default:
                if s.hasPrefix("<<"), let end = s.range(of: ">>") {
                    let stereo = clean(String(s[s.index(s.startIndex, offsetBy: 2)..<end.lowerBound]))
                    let id = String(s[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                    guard let idx = ensureClass(id) else { return false }
                    d.classes[idx].stereo = stereo
                    return true
                }
                if tryRelation(s) {
                    return true
                }
                if let colon = s.firstIndex(of: ":") {
                    let lhs = String(s[..<colon])
                    let member = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    guard let id = styles.stripInline(lhs), let idx = ensureClass(id) else { return false }
                    addMember(idx, member)
                    return !isOver
                }
                return false
            }
        }

        mutating func classDecl(_ rest: String) -> Bool {
            let opens = rest.hasSuffix("{")
            let rawCore = opens ? String(rest.dropLast()).trimmingCharacters(in: .whitespaces) : rest
            var core = rawCore
            var inlineStereo: String?
            if let at = rawCore.range(of: "<<"),
               let end = rawCore.range(of: ">>", range: at.upperBound..<rawCore.endIndex) {
                inlineStereo = clean(String(rawCore[at.upperBound..<end.lowerBound]))
                core = String(rawCore[..<at.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            guard let stripped = styles.stripInline(core) else { return false }

            let id: String
            let label: String?
            if let b = stripped.firstIndex(of: "["), stripped.hasSuffix("]") {
                id = String(stripped[..<b]).trimmingCharacters(in: .whitespaces)
                let inner = String(stripped[stripped.index(after: b)..<stripped.index(before: stripped.endIndex)])
                label = cleanQuoted(inner)
            } else if let asRange = stripped.range(of: " as ") {
                id = String(stripped[..<asRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                label = cleanQuoted(String(stripped[asRange.upperBound...]))
            } else {
                id = stripped
                label = nil
            }

            if !opens && label == nil && id.contains(",") {
                for part in id.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
                    guard let idx = ensureClass(part) else { return false }
                    if let st = inlineStereo { d.classes[idx].stereo = st }
                }
                return true
            }

            guard let idx = ensureClass(id) else { return false }
            if let l = label { d.classes[idx].label = l }
            if let st = inlineStereo { d.classes[idx].stereo = st }
            if opens { activeClass = idx }
            return true
        }

        mutating func addMember(_ idx: Int, _ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return }
            if t.hasPrefix("<<"), t.hasSuffix(">>"), t.count >= 4 {
                let inner = String(t.dropFirst(2).dropLast(2))
                d.classes[idx].stereo = clean(inner)
                return
            }
            members += 1
            if members > MermaidLimits.maxItems * 4 { isOver = true }
            let cleaned = clean(tildeGenerics(t))
            if cleaned.contains("(") && cleaned.contains(")") {
                d.classes[idx].methods.append(cleaned)
            } else {
                d.classes[idx].fields.append(cleaned)
            }
        }

        mutating func tryRelation(_ s: String) -> Bool {
            let lhsRel: String
            let labelPart: String?
            if let at = findColonOutsideQuotes(s) {
                lhsRel = String(s[..<at])
                labelPart = cleanQuoted(String(s[s.index(after: at)...]))
            } else {
                lhsRel = s
                labelPart = nil
            }
            guard let (pos, rel) = findRel(lhsRel) else { return false }
            let leftStr = String(lhsRel[..<pos]).trimmingCharacters(in: .whitespaces)
            let afterPos = lhsRel.index(pos, offsetBy: rel.tok.count)
            let rightStr = String(lhsRel[afterPos...]).trimmingCharacters(in: .whitespaces)
            guard let (rawLeftId, leftCard) = parseSide(leftStr, left: true),
                  let (rawRightId, rightCard) = parseSide(rightStr, left: false),
                  let leftId = styles.stripInline(rawLeftId),
                  let rightId = styles.stripInline(rawRightId),
                  let fromIdx = ensureClass(leftId),
                  let toIdx = ensureClass(rightId),
                  budget() else { return false }

            var parts: [String] = []
            if let lc = leftCard, !lc.isEmpty { parts.append(lc) }
            if let lbl = labelPart, !lbl.isEmpty { parts.append(lbl) }
            if let rc = rightCard, !rc.isEmpty { parts.append(rc) }
            let label = parts.isEmpty ? nil : parts.joined(separator: " · ")

            let from: Int
            let to: Int
            let start: EdgeHead
            let end: EdgeHead
            if rel.start == .openTriangle && rel.end == .none {
                from = fromIdx; to = toIdx; start = rel.start; end = rel.end
            } else if rel.end == .openTriangle && rel.start == .none {
                from = toIdx; to = fromIdx; start = .openTriangle; end = .none
            } else {
                from = fromIdx; to = toIdx; start = rel.start; end = rel.end
            }

            d.edges.append(LayeredEdge(
                from: from,
                to: to,
                label: label,
                line: rel.line,
                start: start,
                end: end,
                minlen: 1,
                style: .default,
                onCluster: (nil, nil)
            ))
            return true
        }

        mutating func ensureClass(_ raw: String) -> Int? {
            let idPart: String
            let generic: String?
            if let at = raw.firstIndex(of: "~"), raw.hasSuffix("~"), at > raw.startIndex {
                idPart = String(raw[..<at])
                generic = String(raw[raw.index(after: at)..<raw.index(before: raw.endIndex)])
            } else {
                idPart = raw
                generic = nil
            }
            let id = idPart.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            guard validClassId(id) else { return nil }
            let ns = activeNs
            if let idx = ids[id] {
                if d.classes[idx].namespace == nil {
                    d.classes[idx].namespace = ns
                }
                if let g = generic {
                    d.classes[idx].label = "\(id)<\(g)>"
                }
                return idx
            }
            guard budget() else { return nil }
            let label = generic.map { "\(id)<\($0)>" } ?? id
            let idx = d.classes.count
            d.classes.append(ClassNode(id: id, label: label, namespace: ns))
            ids[id] = idx
            return idx
        }
    }

    static func parse(_ header: String, _ body: [String]) -> ClassDiagram? {
        var p = Parser()
        var reader = LenientReader()
        let lines = [header] + body
        for line in lines {
            for stmt in statements(line) {
                if !reader.read(&p, statement: stmt) {
                    return nil
                }
            }
        }
        for (id, idx) in p.ids {
            p.d.classes[idx].style = p.styles.get(id)
        }
        return p.d.classes.isEmpty ? nil : p.d
    }

    private static func validClassId(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    private static func tildeGenerics(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var open = false
        for ch in s {
            if ch == "~" {
                out.append(open ? ">" : "<")
                open.toggle()
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func findColonOutsideQuotes(_ s: String) -> String.Index? {
        var quoted = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "\"" {
                quoted.toggle()
            } else if ch == ":" && !quoted {
                let nextIdx = s.index(after: idx)
                let nextIsColon = nextIdx < s.endIndex && s[nextIdx] == ":"
                let prevIsColon = idx > s.startIndex && s[s.index(before: idx)] == ":"
                if !nextIsColon && !prevIsColon {
                    return idx
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func findRel(_ s: String) -> (String.Index, (tok: String, start: EdgeHead, end: EdgeHead, line: EdgeLine))? {
        var quoted = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "\"" {
                quoted.toggle()
                idx = s.index(after: idx)
                continue
            }
            if quoted {
                idx = s.index(after: idx)
                continue
            }
            let tail = s[idx...]
            if let rel = rels.first(where: { tail.hasPrefix($0.tok) }) {
                if rel.tok == "--" {
                    let prev = idx > s.startIndex ? s[s.index(before: idx)] : nil
                    let afterIdx = s.index(idx, offsetBy: rel.tok.count, limitedBy: s.endIndex)
                    let next = (afterIdx != nil && afterIdx! < s.endIndex) ? s[afterIdx!] : nil
                    if let p = prev, let n = next, (p.isLetter || p.isNumber), (n.isLetter || n.isNumber) {
                        idx = s.index(after: idx)
                        continue
                    }
                }
                return (idx, rel)
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func parseSide(_ s: String, left: Bool) -> (String, String?)? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if left && trimmed.hasSuffix("\"") {
            let withoutEnd = String(trimmed.dropLast())
            guard let q = withoutEnd.lastIndex(of: "\"") else { return nil }
            let card = clean(String(withoutEnd[withoutEnd.index(after: q)...]))
            return (String(withoutEnd[..<q]).trimmingCharacters(in: .whitespaces), card)
        }
        if !left && trimmed.hasPrefix("\"") {
            let rest = String(trimmed.dropFirst())
            guard let q = rest.firstIndex(of: "\"") else { return nil }
            let card = clean(String(rest[..<q]))
            return (String(rest[rest.index(after: q)...]).trimmingCharacters(in: .whitespaces), card)
        }
        return (trimmed, nil)
    }
}

enum ClassDrawer {
    private static let spacing = LayeredLayout.Spacing(node: 38.0, rank: 48.0, cluster: 16.0)

    static func draw(
        _ d: ClassDiagram,
        paint: MermaidTheme,
        hover: (MermaidHover, Color)? = nil
    ) -> MermaidScene? {
        let nodes = d.classes.map { c in
            LayeredDrawer.classBox(
                stereo: c.stereo,
                name: c.label,
                fields: c.fields,
                methods: c.methods,
                cluster: c.namespace,
                style: c.style,
                paint: paint
            )
        }
        let clusters = d.namespaces.map { ClusterSpec(title: $0.title, parent: nil) }
        return LayeredDrawer.drawLayered(
            dir: d.dir,
            nodes: nodes,
            edges: d.edges,
            clusters: clusters,
            spacing: spacing,
            paint: paint,
            hover: hover
        )
    }
}
