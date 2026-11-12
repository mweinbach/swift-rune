import Foundation
import Rune

struct BlockDiagram: Sendable {
    enum ArrowPoint: Equatable, Sendable {
        case right, left, up, down, x, y
    }

    enum Kind: Equatable, Sendable {
        case node
        case space
        case arrow(ArrowPoint)
        case group(columns: Int?, children: [Int])
    }

    struct Block: Sendable {
        var id: String
        var label: String
        var shape: NodeShape
        var span: Int
        var kind: Kind
        var style: NodeStyle
    }

    var blocks: [Block]
    var edges: [LayeredEdge]
}

enum BlockParser {
    private static let gap: Float = 10.0
    private static let pad: Float = 10.0
    private static let edgeGap: Float = 40.0

    private struct Item {
        var id: String
        var label: String?
        var shape: NodeShape?
        var arrow: BlockDiagram.ArrowPoint?
        var span: Int
    }

    static func parse(_ body: [String]) -> BlockDiagram? {
        let root = BlockDiagram.Block(
            id: "",
            label: "",
            shape: .rect,
            span: 1,
            kind: .group(columns: nil, children: []),
            style: .default
        )
        var d = BlockDiagram(blocks: [root], edges: [])
        var ids: [String: Int] = [:]
        var stack = [0]
        var styles = StyleSheet()
        var over = false

        func budget() -> Bool {
            if d.blocks.count + d.edges.count >= MermaidLimits.maxItems {
                over = true
                return false
            }
            return true
        }

        func currentGroup() -> Int {
            stack.last ?? 0
        }

        func add(_ it: Item) -> Int? {
            if let existing = ids[it.id] {
                if let l = it.label { d.blocks[existing].label = l }
                if let s = it.shape { d.blocks[existing].shape = s }
                return existing
            }
            guard budget() else { return nil }
            let kind: BlockDiagram.Kind
            if it.id == "space" {
                kind = .space
            } else if let p = it.arrow {
                kind = .arrow(p)
            } else {
                kind = .node
            }
            let label = it.label ?? it.id
            let i = d.blocks.count
            if kind != .space && !it.id.isEmpty {
                ids[it.id] = i
            }
            d.blocks.append(BlockDiagram.Block(
                id: it.id,
                label: label,
                shape: it.shape ?? .rect,
                span: it.span,
                kind: kind,
                style: .default
            ))
            let g = currentGroup()
            if case .group(let cols, var children) = d.blocks[g].kind {
                children.append(i)
                d.blocks[g].kind = .group(columns: cols, children: children)
            }
            return i
        }

        func parseEdges(_ s: String) -> Bool {
            var c = StringScanner(s)
            guard let first = parseItem(&c) else { return false }
            var refs = [first]
            var links: [FlowchartLink] = []
            while true {
                c.skipWS()
                if c.done { break }
                guard let l = FlowchartParser.parseLink(&c) else { return false }
                links.append(l)
                c.skipWS()
                guard let next = parseItem(&c) else { return false }
                refs.append(next)
            }
            if links.isEmpty { return false }
            var ends: [Int] = []
            for r in refs {
                guard let idx = add(r) else { return false }
                ends.append(idx)
            }
            for (l, w) in zip(links, zip(ends, ends.dropFirst())) {
                guard budget() else { return false }
                d.edges.append(LayeredEdge(
                    from: w.0,
                    to: w.1,
                    label: l.label,
                    line: l.line,
                    start: l.start,
                    end: l.end,
                    minlen: 1,
                    style: .default,
                    onCluster: (nil, nil)
                ))
            }
            return true
        }

        func parseItems(_ s: String) {
            var c = StringScanner(s)
            var items: [Item] = []
            while true {
                c.skipWS()
                if c.done { break }
                guard let it = parseItem(&c) else { return }
                items.append(it)
            }
            for it in items {
                _ = add(it)
            }
        }

        for line in body {
            for s in statements(line) {
                if let rest = word(s, "columns") {
                    let n = Int(rest.trimmingCharacters(in: .whitespaces)).map { min(max($0, 1), 24) }
                    let g = currentGroup()
                    if case let .group(_, children) = d.blocks[g].kind {
                        d.blocks[g].kind = .group(columns: n, children: children)
                    }
                } else if s == "end" {
                    if stack.count > 1 { stack.removeLast() }
                } else if s == "block" || s.hasPrefix("block:") {
                    let tail = String(s.dropFirst("block".count)).drop(while: { $0 == ":" })
                    let parts = tail.split(separator: ":", omittingEmptySubsequences: false)
                    let id = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    let spanVal = parts.dropFirst().first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
                    let span = min(max(spanVal, 1), 24)
                    if stack.count > MermaidLimits.maxDepth {
                        over = true
                        return nil
                    }
                    if let i = add(Item(id: id, label: "", shape: nil, arrow: nil, span: span)) {
                        d.blocks[i].kind = .group(columns: nil, children: [])
                        stack.append(i)
                    }
                } else if let rest = word(s, "classDef") {
                    styles.classDef(rest)
                } else if let rest = word(s, "class") {
                    styles.assignClasses(rest)
                } else if let rest = word(s, "style") {
                    styles.style(rest)
                } else if !parseEdges(s) {
                    parseItems(s)
                }
                if over { return nil }
            }
        }

        for (id, i) in ids {
            d.blocks[i].style = styles.get(id)
        }
        return d.blocks.count > 1 ? d : nil
    }

    private static func parseItem(_ c: inout StringScanner) -> Item? {
        guard let id = FlowchartParser.ident(&c) else { return nil }
        var label: String? = nil
        var shapeOf: NodeShape? = nil
        var arrow: BlockDiagram.ArrowPoint? = nil

        if c.eat("<[") {
            guard let closeRange = c.rest.range(of: "]>") else { return nil }
            label = cleanQuoted(String(c.rest[..<closeRange.lowerBound]))
            c.i = closeRange.upperBound
            guard c.rest.hasPrefix("("), let rp = c.rest.dropFirst().firstIndex(of: ")") else { return nil }
            let dir = c.rest[c.rest.index(after: c.rest.startIndex)..<rp].trimmingCharacters(in: .whitespaces)
            c.i = c.rest.index(after: rp)
            switch dir {
            case "right": arrow = .right
            case "left": arrow = .left
            case "up": arrow = .up
            case "down": arrow = .down
            case "x": arrow = .x
            case "y": arrow = .y
            default: return nil
            }
        } else if let (l, s) = FlowchartParser.parseShape(&c) {
            label = l
            shapeOf = s
        }

        var span = 1
        if c.peek() == ":", let d = c.peek2(), d.isASCII, d.isNumber {
            c.bump()
            let start = c.i
            while let ch = c.peek(), ch.isASCII, ch.isNumber {
                c.bump()
            }
            guard let v = Int(c.s[start..<c.i]) else { return nil }
            span = min(max(v, 1), 24)
        }
        return Item(id: id, label: label, shape: shapeOf, arrow: arrow, span: span)
    }

    private static func rows(in d: BlockDiagram, group g: Int) -> (Int, [[(Int, Int)]]) {
        guard case let .group(columns, children) = d.blocks[g].kind else { return (1, []) }
        let cols = max(columns ?? children.reduce(0) { $0 + d.blocks[$1].span }, 1)
        var out: [[(Int, Int)]] = [[]]
        var at = 0
        for k in children {
            let span = min(d.blocks[k].span, cols)
            if at > 0 && at + span > cols {
                out.append([])
                at = 0
            }
            out[out.count - 1].append((k, at))
            at += span
        }
        return (cols, out)
    }

    private struct Layout {
        let d: BlockDiagram
        var labels: [Measured]
        var natural: [Vec2]
        var rects: [(Float, Float, Float, Float)]
        var rowGap: Float

        static func pad(_ g: Int) -> Float { g == 0 ? 0.0 : BlockParser.pad }

        mutating func measure(_ i: Int) -> Vec2 {
            let m = labels[i]
            let size: Vec2
            switch d.blocks[i].kind {
            case .space:
                size = .zero
            case .node:
                size = ShapeRenderer.nodeSize(d.blocks[i].shape, labelSize: m.size)
            case let .arrow(p):
                switch p {
                case .up, .down, .y:
                    size = Vec2(m.size.x + 40.0, m.size.y + 56.0)
                case .left, .right, .x:
                    size = Vec2(m.size.x + 64.0, m.size.y + 36.0)
                }
            case .group:
                let (cols, rList) = BlockParser.rows(in: d, group: i)
                var cell: Float = 0.0
                var height: Float = 0.0
                for row in rList {
                    var tall: Float = 0.0
                    for (k, _) in row {
                        let s = measure(k)
                        let span = Float(min(d.blocks[k].span, cols))
                        cell = max(cell, (s.x - (span - 1.0) * BlockParser.gap) / span)
                        tall = max(tall, s.y)
                    }
                    height += tall
                }
                let p = Layout.pad(i)
                let w = Float(cols) * cell + Float(cols - 1) * BlockParser.gap + 2.0 * p
                let h = height + max(Float(rList.count - 1), 0.0) * rowGap + 2.0 * p
                size = Vec2(w, h)
            }
            natural[i] = size
            return size
        }

        mutating func place(_ i: Int, rect r: (Float, Float, Float, Float)) {
            rects[i] = r
            guard case .group = d.blocks[i].kind else { return }
            let (cols, rList) = BlockParser.rows(in: d, group: i)
            let p = Layout.pad(i)
            let cell = (r.2 - 2.0 * p - Float(cols - 1) * BlockParser.gap) / Float(cols)
            var y = r.1 + p + max(r.3 - natural[i].y, 0.0) * 0.5
            for row in rList {
                let tall = row.map { natural[$0.0].y }.max() ?? 0.0
                for (k, at) in row {
                    let span = Float(min(d.blocks[k].span, cols))
                    let x = r.0 + p + Float(at) * (cell + BlockParser.gap)
                    place(k, rect: (x, y, span * cell + (span - 1.0) * BlockParser.gap, tall))
                }
                y += tall + rowGap
            }
        }

        func frame(_ i: Int) -> (Vec2, Vec2) {
            let (x, y, w, h) = rects[i]
            let n = natural[i]
            let size: Vec2
            switch d.blocks[i].kind {
            case .group: size = Vec2(w, h)
            case .arrow: size = n
            default:
                if d.blocks[i].shape == .circle || d.blocks[i].shape == .doubleCircle {
                    size = n
                } else {
                    size = Vec2(w, n.y)
                }
            }
            return (Vec2(x + w * 0.5, y + h * 0.5), size)
        }
    }

    static func draw(_ d: BlockDiagram, paint: MermaidTheme) -> MermaidScene? {
        let n = d.blocks.count
        var l = Layout(
            d: d,
            labels: d.blocks.map { measureWrap($0.label, font: paint.font, maxWidth: 180.0) },
            natural: Array(repeating: .zero, count: n),
            rects: Array(repeating: (0, 0, 0, 0), count: n),
            rowGap: d.edges.isEmpty ? gap : edgeGap
        )
        let rootSize = l.measure(0)
        l.place(0, rect: (0.0, 0.0, rootSize.x, rootSize.y))

        var c = Canvas()
        let borderCol = groupBorder(paint)
        for i in 1..<n {
            if case .group = d.blocks[i].kind {
                let (x, y, w, h) = l.rects[i]
                let fill = d.blocks[i].style.fill != nil ? d.blocks[i].style.resolve(against: paint).0 : paint.clusterFill
                c.shape(CanvasMath.roundedRect(x0: x, y0: y, x1: x + w, y1: y + h, r: 6.0), fill: fill, border: borderCol, width: 1.0)
            }
        }

        let edgeFont = MermaidChart.small(paint)
        for e in d.edges {
            let (ca, sa) = l.frame(e.from)
            let (cb, sb) = l.frame(e.to)
            func outlineShape(_ i: Int) -> NodeShape {
                if case .node = d.blocks[i].kind { return d.blocks[i].shape }
                return .rect
            }
            let pa = ShapeRenderer.boundary(shape: outlineShape(e.from), center: ca, size: sa, toward: cb)
            let pb = ShapeRenderer.boundary(shape: outlineShape(e.to), center: cb, size: sb, toward: ca)
            let u = CanvasMath.unit(pa, pb)
            let a = Vec2(pa.x + u.x * ConnectorRenderer.inset(for: e.start), pa.y + u.y * ConnectorRenderer.inset(for: e.start))
            let b = Vec2(pb.x - u.x * ConnectorRenderer.inset(for: e.end), pb.y - u.y * ConnectorRenderer.inset(for: e.end))
            ConnectorRenderer.drawConnector(into: &c, runs: [[a, b]], tips: ((pa, Vec2(-u.x, -u.y)), (pb, u)), edge: e, paint: paint)
            if let text = e.label {
                let m = measureWrap(text, font: edgeFont, maxWidth: 160.0)
                let mid = Vec2((pa.x + pb.x) * 0.5, (pa.y + pb.y) * 0.5)
                let s = ConnectorRenderer.labelBox(m)
                c.fill(CanvasMath.roundedRect(x0: mid.x - s.x * 0.5, y0: mid.y - s.y * 0.5, x1: mid.x + s.x * 0.5, y1: mid.y + s.y * 0.5, r: 4.0), color: paint.surface)
                c.label(m, center: mid, font: edgeFont, color: paint.text, align: .center)
            }
        }

        for (i, b) in d.blocks.enumerated().dropFirst() {
            let (ctr, size) = l.frame(i)
            let colors = b.style.resolve(against: paint)
            switch b.kind {
            case .node:
                ShapeRenderer.draw(into: &c, shape: b.shape, label: l.labels[i], center: ctr, size: size, colors: (colors.0, colors.1, colors.2), paint: paint)
            case let .arrow(p):
                c.shape(arrowOutline(p, center: ctr, size: size), fill: colors.0, border: colors.1, width: 1.0)
                c.label(l.labels[i], center: ctr, font: paint.font, color: colors.2, align: .center)
            case .space, .group:
                break
            }
        }
        return c.finishFitMutating(paint: paint)
    }

    private static func arrowOutline(_ p: BlockDiagram.ArrowPoint, center ctr: Vec2, size: Vec2) -> [Vec2] {
        let upright = p == .up || p == .down || p == .y
        let (len, thick) = upright ? (size.y, size.x) : (size.x, size.y)
        let hl = len * 0.5
        let ht = thick * 0.5
        let head = min(thick * 0.55, len * 0.4)
        let shaft = ht * 0.62
        let both = p == .x || p == .y
        let back = both ? (-hl + head) : -hl
        var pts: [Vec2] = [
            Vec2(back, -shaft),
            Vec2(hl - head, -shaft),
            Vec2(hl - head, -ht),
            Vec2(hl, 0.0),
            Vec2(hl - head, ht),
            Vec2(hl - head, shaft),
            Vec2(back, shaft),
        ]
        if both {
            pts.append(contentsOf: [Vec2(back, ht), Vec2(-hl, 0.0), Vec2(back, -ht)])
        }
        let flip = p == .left || p == .up
        return pts.map { pt in
            let u = flip ? -pt.x : pt.x
            let v = pt.y
            return upright ? Vec2(ctr.x + v, ctr.y + u) : Vec2(ctr.x + u, ctr.y + v)
        }
    }
}
