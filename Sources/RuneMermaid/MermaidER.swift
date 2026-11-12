import Foundation
import Rune

// MARK: - Entity-Relationship Diagram AST & Parser

struct ErAttr: Equatable {
    var ty: String = ""
    var name: String = ""
    var keys: String = ""
    var comment: String = ""
}

struct ErEntity: Equatable {
    var id: String
    var label: String
    var attrs: [ErAttr] = []
    var style: NodeStyle = .default
}

struct ErDiagram {
    var title: String?
    var dir: DiagramDirection = .down
    var entities: [ErEntity] = []
    var edges: [LayeredEdge] = []
}

enum ErParser {
    private struct Parser: LenientParser {
        struct Mark {
            let entities: Int
            let edges: Int
        }

        var d = ErDiagram()
        var ids: [String: Int] = [:]
        var open: Int?
        var styles = StyleSheet()
        var attrs = 0
        var isOver = false

        func mark() -> Mark {
            Mark(entities: d.entities.count, edges: d.edges.count)
        }

        mutating func undo(_ mark: Mark) {
            if d.entities.count > mark.entities {
                d.entities.removeSubrange(mark.entities...)
            }
            if d.edges.count > mark.edges {
                d.edges.removeSubrange(mark.edges...)
            }
            ids = ids.filter { $0.value < mark.entities }
        }

        func isOverLimit() -> Bool { isOver }

        mutating func readStatement(_ s: String) -> Bool {
            statement(s)
        }

        mutating func budget() -> Bool {
            if d.entities.count + d.edges.count >= MermaidLimits.maxItems || attrs > MermaidLimits.maxItems * 4 {
                isOver = true
            }
            return !isOver
        }

        mutating func statement(_ s: String) -> Bool {
            if let idx = open {
                if s == "}" {
                    open = nil
                    return true
                }
                guard let attr = parseAttr(s) else { return false }
                attrs += 1
                guard budget() else { return false }
                d.entities[idx].attrs.append(attr)
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
                d.dir = parsed
                return true
            case "accTitle", "accDescr":
                return true
            case "classDef":
                return styles.classDef(String(s.dropFirst("classDef".count)))
            case "class":
                let rest = String(s.dropFirst("class".count)).trimmingCharacters(in: .whitespaces)
                guard let ws = rest.lastIndex(where: \.isWhitespace) else { return false }
                let idList = rest[..<ws]
                let cls = rest[ws...].trimmingCharacters(in: .whitespaces)
                for id in idList.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    styles.addClass(id, cls)
                }
                return true
            case "style":
                return styles.style(String(s.dropFirst("style".count)))
            default:
                break
            }

            if relation(s) {
                return true
            }

            let head: String
            let block: String?
            if let at = s.firstIndex(of: "{") {
                head = String(s[..<at]).trimmingCharacters(in: .whitespaces)
                block = String(s[s.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            } else {
                head = s
                block = nil
            }

            guard let idx = entity(head) else { return false }
            if let blk = block {
                if blk.isEmpty {
                    open = idx
                } else {
                    guard blk.hasSuffix("}") else { return false }
                    let inner = String(blk.dropLast()).trimmingCharacters(in: .whitespaces)
                    if !inner.isEmpty {
                        guard let attr = parseAttr(inner) else { return false }
                        attrs += 1
                        guard budget() else { return false }
                        d.entities[idx].attrs.append(attr)
                    }
                }
            }
            return true
        }

        mutating func relation(_ s: String) -> Bool {
            let lhs: String
            let rawLabel: String?
            if let at = colonOutsideQuotes(s) {
                lhs = String(s[..<at]).trimmingCharacters(in: .whitespaces)
                rawLabel = cleanQuoted(String(s[s.index(after: at)...]))
            } else {
                lhs = s.trimmingCharacters(in: .whitespaces)
                rawLabel = nil
            }

            guard let (a, start, line, end, b) = symbolic(lhs) ?? worded(lhs),
                  let from = entity(a),
                  let to = entity(b),
                  budget() else { return false }

            let label = rawLabel.flatMap { $0.isEmpty ? nil : $0 }
            d.edges.append(LayeredEdge(
                from: from,
                to: to,
                label: label,
                line: line,
                start: start,
                end: end,
                minlen: 1,
                style: .default,
                onCluster: (nil, nil)
            ))
            return true
        }

        mutating func entity(_ rawInput: String) -> Int? {
            let rawPart: String
            let cls: String?
            if let range = rawInput.range(of: ":::") {
                rawPart = String(rawInput[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                cls = String(rawInput[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                rawPart = rawInput.trimmingCharacters(in: .whitespaces)
                cls = nil
            }

            let idRaw: String
            let alias: String?
            if let at = rawPart.firstIndex(of: "["), rawPart.hasSuffix("]"), at > rawPart.startIndex {
                idRaw = String(rawPart[..<at]).trimmingCharacters(in: .whitespaces)
                alias = cleanQuoted(String(rawPart[rawPart.index(after: at)..<rawPart.index(before: rawPart.endIndex)]))
            } else {
                idRaw = rawPart
                alias = nil
            }

            let id: String
            if idRaw.hasPrefix("\""), idRaw.hasSuffix("\""), idRaw.count >= 2 {
                let inner = String(idRaw.dropFirst().dropLast())
                guard !inner.isEmpty, !inner.contains("\"") else { return nil }
                id = inner
            } else if validId(idRaw) {
                id = idRaw
            } else {
                return nil
            }

            if let c = cls {
                styles.addClass(id, c)
            }

            let idx: Int
            if let existing = ids[id] {
                idx = existing
            } else {
                guard budget() else { return nil }
                idx = d.entities.count
                d.entities.append(ErEntity(id: id, label: clean(id)))
                ids[id] = idx
            }

            if let a = alias, !a.isEmpty {
                d.entities[idx].label = a
            }
            return idx
        }
    }

    static func parse(_ header: String, _ body: [String]) -> ErDiagram? {
        var p = Parser()
        var reader = LenientReader()
        for line in [header] + body {
            for stmt in statements(line) {
                if !reader.read(&p, statement: stmt) {
                    return nil
                }
            }
        }
        for (id, idx) in p.ids {
            p.d.entities[idx].style = p.styles.get(id)
        }
        return p.d.entities.isEmpty ? nil : p.d
    }

    private static func validId(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == "*" }
    }

    private static func symbolic(_ s: String) -> (String, EdgeHead, EdgeLine, EdgeHead, String)? {
        let bytes = Array(s.utf8)
        guard bytes.count >= 6 else { return nil }
        for i in 2..<(bytes.count - 3) {
            let line: EdgeLine
            if bytes[i] == UInt8(ascii: "-") && bytes[i + 1] == UInt8(ascii: "-") {
                line = .solid
            } else if bytes[i] == UInt8(ascii: ".") && bytes[i + 1] == UInt8(ascii: ".") {
                line = .dotted
            } else {
                continue
            }

            let left: EdgeHead
            switch (bytes[i - 2], bytes[i - 1]) {
            case (UInt8(ascii: "|"), UInt8(ascii: "|")): left = .onlyOne
            case (UInt8(ascii: "|"), UInt8(ascii: "o")): left = .zeroOrOne
            case (UInt8(ascii: "}"), UInt8(ascii: "|")): left = .oneOrMore
            case (UInt8(ascii: "}"), UInt8(ascii: "o")): left = .zeroOrMore
            default: continue
            }

            let right: EdgeHead
            switch (bytes[i + 2], bytes[i + 3]) {
            case (UInt8(ascii: "|"), UInt8(ascii: "|")): right = .onlyOne
            case (UInt8(ascii: "o"), UInt8(ascii: "|")): right = .zeroOrOne
            case (UInt8(ascii: "|"), UInt8(ascii: "{")): right = .oneOrMore
            case (UInt8(ascii: "o"), UInt8(ascii: "{")): right = .zeroOrMore
            default: continue
            }

            guard let leftPrefix = String(bytes: bytes[..<(i - 2)], encoding: .utf8),
                  let rightSuffix = String(bytes: bytes[(i + 4)...], encoding: .utf8) else { continue }
            let a = leftPrefix.trimmingCharacters(in: .whitespaces)
            let z = rightSuffix.trimmingCharacters(in: .whitespaces)
            if a.isEmpty || z.isEmpty { return nil }
            return (a, left, line, right, z)
        }
        return nil
    }

    private static func worded(_ s: String) -> (String, EdgeHead, EdgeLine, EdgeHead, String)? {
        guard let (a, rest) = firstToken(s),
              let (mid, z) = lastToken(rest) else { return nil }
        let words = mid.trimmingCharacters(in: .whitespaces)
        let leftStr: String
        let line: EdgeLine
        let rightStr: String
        if let optRange = words.range(of: " optionally to ") {
            leftStr = String(words[..<optRange.lowerBound])
            line = .dotted
            rightStr = String(words[optRange.upperBound...])
        } else if let toRange = words.range(of: " to ") {
            leftStr = String(words[..<toRange.lowerBound])
            line = .solid
            rightStr = String(words[toRange.upperBound...])
        } else {
            return nil
        }
        guard let l = card(leftStr.trimmingCharacters(in: .whitespaces)),
              let r = card(rightStr.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (a, l, line, r, z)
    }

    private static func card(_ s: String) -> EdgeHead? {
        switch s.lowercased() {
        case "only one", "1", "one", "exactly one": .onlyOne
        case "zero or one", "one or zero": .zeroOrOne
        case "one or more", "one or many", "many(1)", "1+": .oneOrMore
        case "zero or more", "zero or many", "many(0)", "0+", "many": .zeroOrMore
        default: nil
        }
    }

    private static func firstToken(_ s: String) -> (String, String)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") {
            let afterFirst = t.index(after: t.startIndex)
            guard let endQ = t[afterFirst...].firstIndex(of: "\"") else { return nil }
            let end = t.index(after: endQ)
            return (String(t[..<end]), String(t[end...]))
        }
        guard let ws = t.firstIndex(where: \.isWhitespace) else { return nil }
        return (String(t[..<ws]), String(t[ws...]))
    }

    private static func lastToken(_ s: String) -> (String, String)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("\"") {
            let withoutEnd = t.dropLast()
            guard let startQ = withoutEnd.lastIndex(of: "\"") else { return nil }
            return (String(t[..<startQ]), String(t[startQ...]))
        }
        guard let ws = t.lastIndex(where: \.isWhitespace) else { return nil }
        let afterWs = t.index(after: ws)
        return (String(t[..<afterWs]), String(t[afterWs...]))
    }

    private static func colonOutsideQuotes(_ s: String) -> String.Index? {
        var quoted = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "\"" {
                quoted.toggle()
            } else if ch == ":" && !quoted {
                let startsTriple = s[idx...].hasPrefix(":::")
                let prevColon = idx > s.startIndex && s[s.index(before: idx)] == ":"
                if !startsTriple && !prevColon {
                    return idx
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func parseAttr(_ s: String) -> ErAttr? {
        let body: String
        let comment: String
        if let q = s.firstIndex(of: "\"") {
            body = String(s[..<q]).trimmingCharacters(in: .whitespaces)
            comment = cleanQuoted(String(s[q...]))
        } else {
            body = s.trimmingCharacters(in: .whitespaces)
            comment = ""
        }
        let words = body.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return nil }
        let ty = words[0]
        let name = words[1]
        var keys: [String] = []
        for w in words.dropFirst(2) {
            for k in w.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
                switch k {
                case "PK", "FK", "UK":
                    keys.append(k)
                default:
                    return nil
                }
            }
        }
        return ErAttr(ty: generics(ty), name: name, keys: keys.joined(separator: ", "), comment: comment)
    }

    private static func generics(_ s: String) -> String {
        var open = false
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch == "~" {
                open.toggle()
                out.append(open ? "<" : ">")
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

enum ErDrawer {
    private static let spacing = LayeredLayout.Spacing(node: 40.0, rank: 52.0, cluster: 16.0)

    static func draw(
        _ d: ErDiagram,
        paint: MermaidTheme,
        hover: (MermaidHover, Color)? = nil
    ) -> MermaidScene? {
        var headFont = paint.font
        headFont.weight = 600.0
        var rowFont = paint.font
        rowFont.size = paint.font.size - 1.0
        rowFont.lineHeight = paint.font.resolvedLineHeight - 2.0

        let nodes: [DrawNode] = d.entities.map { e in
            let name = measureWrap(e.label, font: headFont, maxWidth: 220.0)
            let rows: [[Measured]] = e.attrs.map { a in
                [a.ty, a.name, a.keys, a.comment].map { measureWrap($0, font: rowFont, maxWidth: 180.0) }
            }
            var cols = [Float](repeating: 0.0, count: 4)
            for row in rows {
                for i in 0..<4 where !row[i].text.isEmpty {
                    cols[i] = max(cols[i], row[i].size.x + LayeredDrawer.entityPad.x * 2.0)
                }
            }
            let table = cols.reduce(0, +)
            let w = max(max(table, name.size.x + 28.0), 90.0)
            if let lastIdx = cols.lastIndex(where: { $0 > 0.0 }) {
                cols[lastIdx] += w - table
            }
            let rowsHeight = rows.reduce(Float(0)) { $0 + LayeredDrawer.entityRowH($1) }
            let h = name.size.y + LayeredDrawer.entityPad.y * 2.0 + rowsHeight
            return .entity(name: name, rows: rows, cols: cols, size: Vec2(w, max(h, 36.0)), style: e.style)
        }

        return LayeredDrawer.drawLayered(
            dir: d.dir,
            nodes: nodes,
            edges: d.edges,
            clusters: [],
            spacing: spacing,
            paint: paint,
            hover: hover
        )
    }
}
