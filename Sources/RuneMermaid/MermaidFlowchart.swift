import Foundation
import Rune

struct FlowchartNode {
    var id: String
    var label: String
    var shape: NodeShape
    var cluster: Int?
    var style: NodeStyle
    var explicitShape: Bool
}

struct FlowchartSubgraph {
    var id: String?
    var title: String
    var parent: Int?
}

struct FlowchartDiagram {
    var title: String?
    var dir: DiagramDirection
    var nodes: [FlowchartNode]
    var edges: [LayeredEdge]
    var subgraphs: [FlowchartSubgraph]
}

struct FlowchartLink {
    var id: String?
    var line: EdgeLine
    var start: EdgeHead
    var end: EdgeHead
    var minlen: Int
    var label: String?
}

enum FlowchartParser {
    private static let spacing = LayeredLayout.Spacing(node: 36.0, rank: 44.0, cluster: 14.0)

    static func parse(header: String, body: [String]) -> FlowchartDiagram? {
        let trimmedHeader = header.trimmingCharacters(in: .whitespaces)
        let dirStr: String
        let rest: String
        if let idx = trimmedHeader.firstIndex(where: { $0.isWhitespace || $0 == ";" }) {
            dirStr = String(trimmedHeader[..<idx])
            rest = String(trimmedHeader[idx...])
        } else {
            dirStr = trimmedHeader
            rest = ""
        }
        let dir = DiagramDirection.parse(dirStr) ?? .down
        var p = State(dir: dir)

        for line in [rest] + body {
            for stmt in statements(line) {
                if !p.statement(stmt) && p.over {
                    return nil
                }
            }
        }

        for (id, idx) in p.ids {
            p.f.nodes[idx].style = p.styles.get(id)
        }
        for i in 0..<p.f.edges.count {
            var st = p.defaultEdgeStyle
            if let es = p.edgeStyles[i] {
                st = st.merge(es)
            }
            p.f.edges[i].style = st
        }
        resolveSubgraphEndpoints(&p.f)
        return p.f.nodes.isEmpty ? nil : p.f
    }

    static func draw(_ f: FlowchartDiagram, paint: MermaidTheme, hover: (MermaidHover, Color)?) -> MermaidScene? {
        drawCanvas(f, paint: paint, hover: hover)?.finishFit(paint: paint)
    }

    static func drawCanvas(_ f: FlowchartDiagram, paint: MermaidTheme, hover: (MermaidHover, Color)?) -> Canvas? {
        let nodes: [DrawNode] = f.nodes.map { n in
            let label = measureBalanced(n.label, font: paint.font)
            return .shape(shape: n.shape, label: label, size: ShapeRenderer.nodeSize(n.shape, labelSize: label.size), cluster: n.cluster, style: n.style)
        }
        let clusters = f.subgraphs.map { ClusterSpec(title: $0.title, parent: $0.parent) }
        let names = partNames(f)
        guard var c = LayeredDrawer.layeredCanvas(
            dir: f.dir,
            nodes: nodes,
            ids: names.nodes,
            edges: f.edges,
            clusters: clusters,
            spacing: spacing,
            paint: paint,
            hover: hover
        ) else { return nil }
        c.names = names
        return c
    }

    private static func partNames(_ f: FlowchartDiagram) -> PartNames {
        let frames = f.subgraphs.enumerated().map { (i, s) in s.id ?? "#\(i)" }
        return PartNames.fromLayered(
            nodes: f.nodes.map(\.id),
            edges: f.edges.map { ($0.from, $0.to) },
            frames: frames
        )
    }

    private static func resolveSubgraphEndpoints(_ f: inout FlowchartDiagram) {
        var redirects: [Int: (first: Int, last: Int, sg: Int)] = [:]
        for (sgIdx, sg) in f.subgraphs.enumerated() {
            guard let id = sg.id else { continue }
            guard let nodeIdx = f.nodes.firstIndex(where: { $0.id == id && !$0.explicitShape }) else { continue }
            let members = (0..<f.nodes.count).filter { $0 != nodeIdx && inCluster(nodeIdx: $0, target: sgIdx, nodes: f.nodes, subgraphs: f.subgraphs) }
            if let first = members.first, let last = members.last {
                redirects[nodeIdx] = (first, last, sgIdx)
            }
        }
        if redirects.isEmpty { return }
        for i in 0..<f.edges.count {
            let from = f.edges[i].from
            let to = f.edges[i].to
            func inside(_ v: Int, _ sg: Int) -> Bool {
                if let r = redirects[v] {
                    var cur: Int? = r.sg
                    var steps = 0
                    while let s = cur, steps <= f.subgraphs.count {
                        if s == sg { return true }
                        cur = f.subgraphs[s].parent
                        steps += 1
                    }
                    return false
                }
                return inCluster(nodeIdx: v, target: sg, nodes: f.nodes, subgraphs: f.subgraphs)
            }
            if let r = redirects[from] {
                f.edges[i].from = r.last
                f.edges[i].onCluster.0 = inside(to, r.sg) ? nil : r.sg
            }
            if let r = redirects[to] {
                f.edges[i].to = r.first
                f.edges[i].onCluster.1 = inside(from, r.sg) ? nil : r.sg
            }
        }
        var keep: [FlowchartNode] = []
        var remap = Array(repeating: 0, count: f.nodes.count)
        for i in 0..<f.nodes.count where redirects[i] == nil {
            remap[i] = keep.count
            keep.append(f.nodes[i])
        }
        f.nodes = keep
        for i in 0..<f.edges.count {
            f.edges[i].from = remap[f.edges[i].from]
            f.edges[i].to = remap[f.edges[i].to]
        }
    }

    private static func inCluster(nodeIdx: Int, target: Int, nodes: [FlowchartNode], subgraphs: [FlowchartSubgraph]) -> Bool {
        var cur = nodes[nodeIdx].cluster
        var steps = 0
        while let c = cur, steps <= subgraphs.count {
            if c == target { return true }
            cur = subgraphs[c].parent
            steps += 1
        }
        return false
    }

    private struct NodeRef {
        var id: String
        var shape: (String?, NodeShape)?
        var cls: String?
    }

    private struct State {
        var f: FlowchartDiagram
        var ids: [String: Int] = [:]
        var stack: [Int] = []
        var styles = StyleSheet()
        var defaultEdgeStyle = EdgeStyle.default
        var edgeStyles: [Int: EdgeStyle] = [:]
        var edgeIds: Set<String> = []
        var over = false

        init(dir: DiagramDirection) {
            self.f = FlowchartDiagram(title: nil, dir: dir, nodes: [], edges: [], subgraphs: [])
        }

        mutating func budget() -> Bool {
            if f.nodes.count + f.edges.count + f.subgraphs.count >= MermaidLimits.maxItems {
                over = true
                return false
            }
            return true
        }

        mutating func statement(_ s: String) -> Bool {
            let wordTok: String
            if let idx = s.firstIndex(where: { $0.isWhitespace || $0 == ":" }) {
                wordTok = String(s[..<idx])
            } else {
                wordTok = s
            }
            switch wordTok {
            case "subgraph":
                let rest = String(s.dropFirst("subgraph".count)).trimmingCharacters(in: .whitespaces)
                let sgId: String?
                let title: String
                if let br = rest.firstIndex(of: "["), rest.hasSuffix("]") {
                    let rawId = String(rest[..<br]).trimmingCharacters(in: .whitespaces)
                    sgId = rawId.isEmpty ? nil : rawId
                    let inner = String(rest[rest.index(after: br)..<rest.index(before: rest.endIndex)])
                    title = cleanQuoted(inner)
                } else {
                    sgId = (!rest.hasPrefix("\"") && !rest.contains(where: \.isWhitespace) && !rest.isEmpty) ? rest : nil
                    title = cleanQuoted(rest)
                }
                guard budget() else { return false }
                if stack.count >= MermaidLimits.maxDepth {
                    over = true
                    return false
                }
                f.subgraphs.append(FlowchartSubgraph(id: sgId, title: title, parent: stack.last))
                stack.append(f.subgraphs.count - 1)
                return true
            case "end" where s == "end":
                return stack.popLast() != nil
            case "title":
                let t = cleanQuoted(String(s.dropFirst("title".count)).trimmingCharacters(in: .whitespaces))
                if !t.isEmpty { f.title = t }
                return true
            case "direction":
                let rest = String(s.dropFirst("direction".count)).trimmingCharacters(in: .whitespaces)
                if stack.isEmpty && f.edges.isEmpty, let d = DiagramDirection.parse(rest) {
                    f.dir = d
                }
                return true
            case "classDef":
                _ = styles.classDef(String(s.dropFirst("classDef".count)))
                return true
            case "class":
                _ = styles.assignClasses(String(s.dropFirst("class".count)))
                return true
            case "style":
                _ = styles.style(String(s.dropFirst("style".count)))
                return true
            case "linkStyle":
                let rest = String(s.dropFirst("linkStyle".count)).trimmingCharacters(in: .whitespaces)
                if let ws = rest.firstIndex(where: \.isWhitespace) {
                    let targets = rest[..<ws]
                    let props = String(rest[ws...])
                    let st = parseEdgeStyleProps(props)
                    for tok in targets.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        if tok == "default" {
                            defaultEdgeStyle = defaultEdgeStyle.merge(st)
                        } else if let idx = Int(tok) {
                            let cur = edgeStyles[idx] ?? .default
                            edgeStyles[idx] = cur.merge(st)
                        }
                    }
                }
                return true
            case "click", "accTitle", "accDescr":
                return true
            default:
                return chain(s)
            }
        }

        mutating func chain(_ s: String) -> Bool {
            if let atRange = s.range(of: "@{") {
                let id = String(s[..<atRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                if edgeIds.contains(id) { return true }
            }
            var c = StringScanner(s)
            guard let firstGroup = parseGroup(&c) else { return false }
            var groups: [[NodeRef]] = [firstGroup]
            var links: [FlowchartLink] = []
            while true {
                c.skipWS()
                if c.done { break }
                guard let l = parseLink(&c) else { return false }
                links.append(l)
                c.skipWS()
                guard let g = parseGroup(&c) else { return false }
                groups.append(g)
            }
            var resolvedGroups: [[Int]] = []
            for g in groups {
                var idxs: [Int] = []
                for nr in g {
                    guard let idx = node(nr) else { return false }
                    idxs.append(idx)
                }
                resolvedGroups.append(idxs)
            }
            for l in links {
                if let lid = l.id { edgeIds.insert(lid) }
            }
            for (k, l) in links.enumerated() {
                for from in resolvedGroups[k] {
                    for to in resolvedGroups[k + 1] {
                        guard budget() else { return false }
                        f.edges.append(LayeredEdge(
                            from: from,
                            to: to,
                            label: l.label,
                            line: l.line,
                            start: l.start,
                            end: l.end,
                            minlen: l.minlen,
                            style: .default,
                            onCluster: (nil, nil)
                        ))
                    }
                }
            }
            return true
        }

        mutating func node(_ r: NodeRef) -> Int? {
            if let cls = r.cls {
                styles.addClass(r.id, cls)
            }
            let cluster = stack.last
            let i: Int
            if let existing = ids[r.id] {
                i = existing
            } else {
                guard budget() else { return nil }
                i = f.nodes.count
                f.nodes.append(FlowchartNode(
                    id: r.id,
                    label: r.id,
                    shape: .rect,
                    cluster: cluster,
                    style: .default,
                    explicitShape: false
                ))
                ids[r.id] = i
            }
            if f.nodes[i].cluster == nil {
                f.nodes[i].cluster = cluster
            }
            if let (lbl, shp) = r.shape {
                if let l = lbl { f.nodes[i].label = l }
                f.nodes[i].shape = shp
                f.nodes[i].explicitShape = true
            }
            return i
        }
    }

    // MARK: - Lexer / Primitives

    private static func parseGroup(_ c: inout StringScanner) -> [NodeRef]? {
        guard let first = parseNodeRef(&c) else { return nil }
        var v = [first]
        while true {
            c.skipWS()
            if !c.eat("&") { return v }
            c.skipWS()
            guard let next = parseNodeRef(&c) else { return nil }
            v.append(next)
        }
    }

    private static func parseNodeRef(_ c: inout StringScanner) -> NodeRef? {
        guard let id = ident(&c) else { return nil }
        let shp = parseShape(&c)
        let cls: String? = c.eat(":::") ? ident(&c) : nil
        return NodeRef(id: id, shape: shp, cls: cls)
    }

    static func ident(_ c: inout StringScanner) -> String? {
        let start = c.i
        func isWord(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }
        while let ch = c.peek() {
            if isWord(ch) || (ch == "-" && c.i > start && c.peek2().map(isWord) == true) {
                c.bump()
            } else {
                break
            }
        }
        return c.i > start ? String(c.s[start..<c.i]) : nil
    }

    private static let shapesTable: [(String, String, NodeShape)] = [
        ("(((", ")))", .doubleCircle),
        ("([", "])", .stadium),
        ("[[", "]]", .subroutine),
        ("[(", ")]", .cylinder),
        ("((", "))", .circle),
        ("{{", "}}", .hexagon),
        (">", "]", .asymmetric),
        ("[", "]", .rect),
        ("(", ")", .round),
        ("{", "}", .diamond),
    ]

    private static func findClose(_ s: Substring, open: String, close: String) -> String.Index? {
        let nested = open.count == 1 && close.count == 1 && open != ">"
        var depth = 1
        var quoted = false
        var escaped = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let rest = s[idx...]
            let ch = s[idx]
            if escaped {
                escaped = false
                idx = s.index(after: idx)
                continue
            }
            if quoted {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { quoted = false }
                idx = s.index(after: idx)
                continue
            }
            if ch == "\"" {
                quoted = true
                idx = s.index(after: idx)
                continue
            }
            if rest.hasPrefix(close) {
                depth -= 1
                if depth == 0 { return idx }
                idx = s.index(idx, offsetBy: close.count)
                continue
            }
            if nested && rest.hasPrefix(open) {
                depth += 1
                idx = s.index(idx, offsetBy: open.count)
                continue
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func findQuoteEnd(_ s: Substring) -> (String, String.Index)? {
        var out = ""
        var escaped = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return (out, s.index(after: idx))
            } else {
                out.append(ch)
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func findUnquoted(_ s: Substring, needle: String) -> String.Index? {
        var quoted = false
        var escaped = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if escaped {
                escaped = false
            } else if quoted {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { quoted = false }
            } else if ch == "\"" {
                quoted = true
            } else if s[idx...].hasPrefix(needle) {
                return idx
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func parseAtShape(_ c: inout StringScanner) -> (String?, NodeShape)? {
        _ = c.eat("@{")
        guard let end = findClose(c.rest, open: "{", close: "}") else { return nil }
        let inner = String(c.rest[..<end])
        var kind = NodeShape.rect
        var label: String? = nil
        for part in splitTopCommas(inner) {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let k = part[..<colon].trimmingCharacters(in: .whitespaces)
            let v = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch k {
            case "shape":
                let name = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
                kind = NodeShape.named(name) ?? .rect
            case "label":
                label = cleanQuoted(v)
            case "form" where kind == .rect:
                let form = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                kind = switch form {
                case "circle": .circle
                case "rounded": .round
                default: .rect
                }
            default: break
            }
        }
        c.i = c.s.index(after: end)
        return (label, kind)
    }

    private static func splitTopCommas(_ s: String) -> [String] {
        var out: [String] = []
        var start = s.startIndex
        var quoted = false
        var escaped = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" && quoted {
                escaped = true
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                let seg = s[start..<idx].trimmingCharacters(in: .whitespaces)
                if !seg.isEmpty { out.append(seg) }
                start = s.index(after: idx)
            }
            idx = s.index(after: idx)
        }
        let tail = s[start...].trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    static func parseShape(_ c: inout StringScanner) -> (String?, NodeShape)? {
        let start = c.i
        guard c.rest.hasPrefix("@{") || (c.peek().map { "([{\"'>".contains($0) } ?? false) else {
            return nil
        }
        if let exact = exactShape(&c) {
            return exact
        }
        c.i = start
        return looseShape(&c)
    }

    private static func exactShape(_ c: inout StringScanner) -> (String?, NodeShape)? {
        if c.rest.hasPrefix("@{") {
            return parseAtShape(&c)
        }
        for open in ["[/", "[\\"] {
            if c.eat(open) {
                guard let end = findClose(c.rest, open: "[", close: "]") else { return nil }
                let inner = c.rest[..<end]
                guard let closeCh = inner.last, closeCh == "/" || closeCh == "\\" else { return nil }
                let label = cleanQuoted(String(inner.dropLast()))
                c.i = c.s.index(after: end)
                let kind: NodeShape = switch (open, closeCh) {
                case ("[/", "/"): .leanRight
                case ("[/", _): .trapBottom
                case (_, "/"): .trapTop
                default: .leanLeft
                }
                return (label, kind)
            }
        }
        guard let (open, close, kind) = shapesTable.first(where: { c.rest.hasPrefix($0.0) }) else { return nil }
        _ = c.eat(open)
        c.skipWS()
        let label: String
        if c.peek() == "\"" {
            c.bump()
            guard let (lbl, usedIdx) = findQuoteEnd(c.rest) else { return nil }
            c.i = usedIdx
            c.skipWS()
            guard c.eat(close) else { return nil }
            label = lbl
        } else {
            guard let end = findClose(c.rest, open: open, close: close) else { return nil }
            label = String(c.rest[..<end])
            c.i = c.s.index(end, offsetBy: close.count)
        }
        return (clean(label), kind)
    }

    private static func looseShape(_ c: inout StringScanner) -> (String?, NodeShape) {
        let rest = c.rest
        let at = rest.hasPrefix("@{")
        let (open, close): (String, String) = switch rest.first {
        case "(": ("(", ")")
        case "{": ("{", "}")
        case ">": (">", "]")
        default: at ? ("{", "}") : ("[", "]")
        }
        let skip = at ? 2 : 1
        let bodyStart = rest.index(rest.startIndex, offsetBy: min(skip, rest.count))
        let body = rest[bodyStart...]
        let text: String
        if let e = findClose(body, open: open, close: close) {
            text = String(body[..<e])
            c.i = c.s.index(after: e)
        } else {
            text = String(body)
            c.i = c.s.endIndex
        }
        let label = cleanQuoted(text)
        return ((!at && !label.isEmpty) ? label : nil, .rect)
    }

    private static func run(_ c: inout StringScanner) -> String {
        let start = c.i
        while let ch = c.peek(), "-=.~".contains(ch) {
            c.bump()
        }
        return String(c.s[start..<c.i])
    }

    private static func endHead(_ c: inout StringScanner) -> EdgeHead {
        switch c.peek() {
        case ">":
            c.bump()
            return .arrow
        case let ch? where (ch == "o" || ch == "x") && (c.peek2().map { $0.isWhitespace || $0 == "|" } ?? true):
            c.bump()
            return ch == "o" ? .circle : .cross
        default:
            return .none
        }
    }

    static func parseLink(_ c: inout StringScanner) -> FlowchartLink? {
        let save = c.i
        var id: String? = nil
        if let candidate = ident(&c), c.eat("@"), let next = c.peek(), "-=.~<ox".contains(next) {
            id = candidate
        } else {
            c.i = save
        }

        let start: EdgeHead
        if c.eat("<") {
            start = .arrow
        } else if let ch = c.peek(), ch == "o" || ch == "x", let p2 = c.peek2(), p2 == "-" || p2 == "=" {
            c.bump()
            start = ch == "o" ? .circle : .cross
        } else {
            start = .none
        }

        let first = run(&c)
        guard first.count >= 2 else { return nil }
        var end = endHead(&c)
        var body = first
        var label: String? = nil

        if end == .none && (first == "--" || first == "==" || first == "-.") {
            let close = first == "-." ? ".-" : first
            guard let at = findUnquoted(c.rest, needle: close) else { return nil }
            let text = cleanQuoted(String(c.rest[..<at]))
            guard !text.isEmpty else { return nil }
            label = text
            c.i = at
            body = run(&c)
            end = endHead(&c)
        }

        let line: EdgeLine
        if body.contains("~") {
            line = .invisible
        } else if body.contains("=") {
            line = .thick
        } else if body.contains(".") {
            line = .dotted
        } else {
            line = .solid
        }

        let rawMinlen: Int
        if line == .dotted {
            rawMinlen = body.filter { $0 == "." }.count
        } else {
            let n = body.filter { $0 == "-" || $0 == "=" || $0 == "~" }.count
            rawMinlen = end == .none ? max(0, n - 2) : max(0, n - 1)
        }
        let minlen = min(max(rawMinlen, 1), LayeredLayout.maxMinlen)

        let savePipe = c.i
        c.skipWS()
        if c.eat("|") {
            guard let at = findUnquoted(c.rest, needle: "|") else { return nil }
            let text = cleanQuoted(String(c.rest[..<at]))
            c.i = c.s.index(after: at)
            if !text.isEmpty { label = text }
        } else {
            c.i = savePipe
        }
        return FlowchartLink(id: id, line: line, start: start, end: end, minlen: minlen, label: label)
    }
}
