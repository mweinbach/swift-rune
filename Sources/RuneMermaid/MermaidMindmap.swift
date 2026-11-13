import Foundation
import Rune

struct MindmapNode: Sendable {
    enum Look: Sendable, Equatable {
        case plain
        case square
        case rounded
        case circle
        case bang
        case cloud
        case hexagon
    }

    var text: String
    var look: Look
    var depth: Int
    var children: [Int]
}

struct MindmapDiagram: Sendable {
    var nodes: [MindmapNode]
    var title: String? = nil
}

enum MindmapParser {
    private static let gapX: Float = 40.0
    private static let gapY: Float = 10.0
    private static let wrapWidth: Float = 150.0

    static func parse(body: [String], indents: [Int]) -> MindmapDiagram? {
        var nodes: [MindmapNode] = []
        var stack: [(Int, Int)] = []

        for (i, line) in body.enumerated() {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("::icon(") || l.hasPrefix(":::") || l.hasPrefix("accTitle") || l.hasPrefix("accDescr") {
                continue
            }
            guard let (text, look) = parseNode(l) else { continue }
            if nodes.count >= MermaidLimits.maxItems { return nil }
            let indent = i < indents.count ? indents[i] : 0
            let id = nodes.count
            if id == 0 {
                nodes.append(MindmapNode(text: text, look: look, depth: 0, children: []))
                stack.append((indent, 0))
                continue
            }
            while stack.count > 1, let last = stack.last, last.0 >= indent {
                stack.removeLast()
            }
            let parent = stack.last?.1 ?? 0
            let depth = nodes[parent].depth + 1
            if depth > MermaidLimits.maxDepth { return nil }
            nodes[parent].children.append(id)
            nodes.append(MindmapNode(text: text, look: look, depth: depth, children: []))
            stack.append((indent, id))
        }
        return nodes.isEmpty ? nil : MindmapDiagram(nodes: nodes)
    }

    private static func parseNode(_ raw: String) -> (String, MindmapNode.Look)? {
        var l = raw
        if let colons = l.range(of: ":::", options: .backwards) {
            let tail = l[colons.lowerBound...]
            if !tail.contains(where: { $0 == ")" || $0 == "]" || $0 == "}" }) {
                l = String(l[..<colons.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        if l.isEmpty { return nil }

        if let p = l.firstIndex(where: { $0 == "[" || $0 == "(" || $0 == ")" || $0 == "{" }) {
            let rest = String(l[p...])
            let shapes: [(String, String, MindmapNode.Look)] = [
                ("((", "))", .circle),
                ("))", "((", .bang),
                ("{{", "}}", .hexagon),
                (")", "(", .cloud),
                ("(", ")", .rounded),
                ("[", "]", .square),
                ("{", "}", .rounded),
            ]
            for (open, close, look) in shapes {
                if rest.hasPrefix(open), rest.hasSuffix(close), rest.count > open.count + close.count {
                    let inner = String(rest.dropFirst(open.count).dropLast(close.count))
                    if !inner.isEmpty {
                        return (cleanQuoted(inner), look)
                    }
                }
            }
        }
        return (cleanQuoted(l), .plain)
    }

    private struct Placed {
        var label: Measured
        var size: Vec2
        var side: Float
        var branch: Int
        var at: Vec2
    }

    static func draw(_ m: MindmapDiagram, paint: MermaidTheme) -> MermaidScene? {
        let n = m.nodes.count
        func font(_ i: Int) -> TextStyle { i == 0 ? MermaidChart.bold(paint.font) : paint.font }
        var placed: [Placed] = (0..<n).map { i in
            let node = m.nodes[i]
            let label = measureWrap(node.text, font: font(i), maxWidth: wrapWidth)
            return Placed(label: label, size: nodeSize(look(i, node.look), label.size), side: 0.0, branch: 0, at: .zero)
        }

        var block = Array(repeating: Float(0.0), count: n)
        for i in (0..<n).reversed() {
            let kids = m.nodes[i].children
            let stacked = kids.reduce(Float(0.0)) { $0 + block[$1] } + gapY * Float(max(kids.count - 1, 0))
            block[i] = max(placed[i].size.y, stacked)
        }

        let top = m.nodes[0].children
        let total = top.reduce(Float(0.0)) { $0 + block[$1] }
        var right: [Int] = []
        var left: [Int] = []
        var held: Float = 0.0
        for k in top {
            if right.isEmpty || held + block[k] * 0.5 <= total * 0.5 {
                held += block[k]
                right.append(k)
            } else {
                left.append(k)
            }
        }
        for (b, k) in top.enumerated() {
            mark(m, placed: &placed, i: k, branch: b, side: right.contains(k) ? 1.0 : -1.0)
        }

        var cols = [
            Array(repeating: Float(0.0), count: MermaidLimits.maxDepth + 1),
            Array(repeating: Float(0.0), count: MermaidLimits.maxDepth + 1),
        ]
        for i in 1..<n {
            let p = placed[i]
            let idx = p.side > 0.0 ? 1 : 0
            let d = m.nodes[i].depth
            cols[idx][d] = max(cols[idx][d], p.size.x)
        }

        for (kids, side) in [(right, Float(1.0)), (left, Float(-1.0))] {
            let col = cols[side > 0.0 ? 1 : 0]
            let height = kids.reduce(Float(0.0)) { $0 + block[$1] } + gapY * Float(max(kids.count - 1, 0))
            var y = -height * 0.5
            for k in kids {
                place(m, placed: &placed, block: block, col: col, i: k, top: y)
                y += block[k] + gapY
            }
        }

        var c = Canvas()
        for (i, node) in m.nodes.enumerated() {
            let p = placed[i]
            for k in node.children {
                let q = placed[k]
                let a = Vec2(p.at.x + q.side * p.size.x * 0.5, p.at.y)
                let b = Vec2(q.at.x - q.side * q.size.x * 0.5, q.at.y)
                let width = max(3.5 - Float(node.depth) * 0.75, 1.25)
                c.stroke(MermaidChart.sCurve(a, b, upright: false), closed: false, width: width, color: MermaidChart.solid(paint, hue: branchHue(q.branch)))
            }
        }
        for (i, node) in m.nodes.enumerated() {
            let p = placed[i]
            let h = branchHue(p.branch)
            let (fill, border): (Color, Color)
            switch node.depth {
            case 0:
                fill = MermaidChart.solid(paint, hue: MermaidChart.hue(0))
                border = MermaidChart.strong(paint, hue: MermaidChart.hue(0))
            case 1:
                fill = MermaidChart.soft(paint, hue: h)
                border = MermaidChart.strong(paint, hue: h)
            default:
                fill = overColor(MermaidChart.soft(paint, hue: h).alpha(0.55), paint.surface)
                border = MermaidChart.strong(paint, hue: h).alpha(0.7)
            }
            let textColor = node.depth == 0 ? MermaidChart.ink(fill) : paint.text
            drawNode(&c, look: look(i, node.look), p: p, fill: fill, border: border, text: textColor, font: font(i))
        }
        return c.finishFitMutating(paint: paint)
    }

    private static func look(_ i: Int, _ l: MindmapNode.Look) -> MindmapNode.Look {
        (i == 0 && l == .plain) ? .rounded : l
    }

    private static func branchHue(_ b: Int) -> Float {
        MermaidChart.hue(b + 1)
    }

    private static func mark(_ m: MindmapDiagram, placed: inout [Placed], i: Int, branch: Int, side: Float) {
        placed[i].side = side
        placed[i].branch = branch
        for k in m.nodes[i].children {
            mark(m, placed: &placed, i: k, branch: branch, side: side)
        }
    }

    private static func place(_ m: MindmapDiagram, placed: inout [Placed], block: [Float], col: [Float], i: Int, top: Float) {
        let node = m.nodes[i]
        let side = placed[i].side
        let inner = col[1..<node.depth].reduce(Float(0.0)) { $0 + $1 + gapX } + placed[0].size.x * 0.5 + gapX
        placed[i].at = Vec2(side * (inner + placed[i].size.x * 0.5), top + block[i] * 0.5)
        let stacked = node.children.reduce(Float(0.0)) { $0 + block[$1] } + gapY * Float(max(node.children.count - 1, 0))
        var y = top + (block[i] - stacked) * 0.5
        for k in node.children {
            place(m, placed: &placed, block: block, col: col, i: k, top: y)
            y += block[k] + gapY
        }
    }

    private static func asShape(_ l: MindmapNode.Look) -> NodeShape? {
        switch l {
        case .circle: return .circle
        case .bang: return .bang
        case .cloud: return .cloud
        case .hexagon: return .hexagon
        default: return nil
        }
    }

    private static func nodeSize(_ l: MindmapNode.Look, _ t: Vec2) -> Vec2 {
        if let s = asShape(l) {
            let sz = ShapeRenderer.nodeSize(s, labelSize: t)
            return l == .hexagon ? Vec2(sz.x, max(t.y + 16.0, 34.0)) : sz
        }
        return Vec2(t.x + 24.0, max(t.y + 14.0, 32.0))
    }

    private static func drawNode(
        _ c: inout Canvas,
        look: MindmapNode.Look,
        p: Placed,
        fill: Color,
        border: Color,
        text: Color,
        font: TextStyle
    ) {
        let x0 = p.at.x - p.size.x * 0.5
        let y0 = p.at.y - p.size.y * 0.5
        let x1 = p.at.x + p.size.x * 0.5
        let y1 = p.at.y + p.size.y * 0.5
        switch look {
        case .plain:
            c.fill(CanvasMath.roundedRect(x0: x0, y0: y0, x1: x1, y1: y1, r: 4.0), color: fill)
            c.stroke([Vec2(x0, y1), Vec2(x1, y1)], closed: false, width: 2.0, color: border)
        case .square:
            c.shape(CanvasMath.roundedRect(x0: x0, y0: y0, x1: x1, y1: y1, r: 0.0), fill: fill, border: border, width: 1.0)
        case .rounded:
            c.shape(CanvasMath.roundedRect(x0: x0, y0: y0, x1: x1, y1: y1, r: 10.0), fill: fill, border: border, width: 1.0)
        case .circle, .bang, .cloud, .hexagon:
            if let s = asShape(look) {
                c.shape(ShapeRenderer.outline(shape: s, center: p.at, size: p.size), fill: fill, border: border, width: 1.0)
            }
        }
        c.label(p.label, center: p.at, font: font, color: text, align: .center)
    }
}
