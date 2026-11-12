import Foundation
import Rune

enum DiagramDirection: Equatable {
    case down
    case up
    case right
    case left

    static func parse(_ s: String) -> DiagramDirection? {
        switch s {
        case "", "TD", "TB": .down
        case "BT": .up
        case "LR": .right
        case "RL": .left
        default: nil
        }
    }
}

enum EdgeLine: Equatable {
    case solid
    case dotted
    case thick
    case invisible
}

enum EdgeHead: Equatable {
    case none
    case arrow
    case circle
    case cross
    case openTriangle
    case diamondFilled
    case diamondOpen
    case onlyOne
    case zeroOrOne
    case oneOrMore
    case zeroOrMore
    case contains
}

struct LayeredEdge: Equatable {
    var from: Int
    var to: Int
    var label: String?
    var line: EdgeLine
    var start: EdgeHead
    var end: EdgeHead
    var minlen: Int
    var style: EdgeStyle
    var onCluster: (Int?, Int?)

    static func == (lhs: LayeredEdge, rhs: LayeredEdge) -> Bool {
        lhs.from == rhs.from
            && lhs.to == rhs.to
            && lhs.label == rhs.label
            && lhs.line == rhs.line
            && lhs.start == rhs.start
            && lhs.end == rhs.end
            && lhs.minlen == rhs.minlen
            && lhs.style == rhs.style
            && lhs.onCluster.0 == rhs.onCluster.0
            && lhs.onCluster.1 == rhs.onCluster.1
    }
}

struct ClusterSpec {
    var title: String
    var parent: Int?
}

enum DrawNode {
    case shape(shape: NodeShape, label: Measured, size: Vec2, cluster: Int?, style: NodeStyle)
    case start(cluster: Int?)
    case end(cluster: Int?)
    case bar(cluster: Int?)
    case classBox(stereo: Measured?, name: Measured, fields: [Measured], methods: [Measured], size: Vec2, cluster: Int?, style: NodeStyle)
    case card(shape: NodeShape, lines: [(Measured, TextStyle)], size: Vec2, cluster: Int?, colors: (Color, Color, Color), person: Bool)
    case entity(name: Measured, rows: [[Measured]], cols: [Float], size: Vec2, style: NodeStyle)

    var size: Vec2 {
        switch self {
        case let .shape(_, _, size, _, _),
             let .classBox(_, _, _, _, size, _, _),
             let .card(_, _, size, _, _, _),
             let .entity(_, _, _, size, _):
            return size
        case .start: return Vec2(18.0, 18.0)
        case .end: return Vec2(22.0, 22.0)
        case .bar: return Vec2(64.0, 8.0)
        }
    }

    var shape: NodeShape {
        switch self {
        case let .shape(s, _, _, _, _),
             let .card(s, _, _, _, _, _):
            return s
        case .start, .end: return .circle
        case .bar, .classBox, .entity: return .rect
        }
    }

    var cluster: Int? {
        switch self {
        case let .shape(_, _, _, c, _),
             let .start(c),
             let .end(c),
             let .bar(c),
             let .classBox(_, _, _, _, _, c, _),
             let .card(_, _, _, c, _, _):
            return c
        case .entity:
            return nil
        }
    }
}

enum LayeredDrawer {
    private static let turnBelow: Float = 0.78
    private static let titleInset = Vec2(12.0, 7.0)
    private static let titleWrap: Float = 420.0
    static let entityPad = Vec2(10.0, 5.0)

    static func smallFont(_ paint: MermaidTheme) -> TextStyle {
        var f = paint.font
        f.size = paint.font.size - 1.0
        f.lineHeight = paint.font.resolvedLineHeight - 2.0
        return f
    }

    static func drawLayered(
        dir: DiagramDirection,
        nodes: [DrawNode],
        edges: [LayeredEdge],
        clusters: [ClusterSpec],
        spacing: LayeredLayout.Spacing,
        paint: MermaidTheme,
        hover: (MermaidHover, Color)?
    ) -> MermaidScene? {
        guard let canvas = layeredCanvas(
            dir: dir,
            nodes: nodes,
            ids: [],
            edges: edges,
            clusters: clusters,
            spacing: spacing,
            paint: paint,
            hover: hover
        ) else { return nil }
        return canvas.finishFit(paint: paint)
    }

    static func layeredCanvas(
        dir: DiagramDirection,
        nodes: [DrawNode],
        ids: [String],
        edges: [LayeredEdge],
        clusters: [ClusterSpec],
        spacing: LayeredLayout.Spacing,
        paint: MermaidTheme,
        hover: (MermaidHover, Color)?
    ) -> Canvas? {
        let edgeFont = smallFont(paint)
        let labels: [Measured?] = edges.map { e in e.label.map { measureBalanced($0, font: edgeFont) } }
        var titleFont = edgeFont
        titleFont.weight = 500.0
        let titles: [Measured] = clusters.map { measureWrap($0.title, font: titleFont, maxWidth: titleWrap) }

        guard var canvas = drawIn(
            dir: dir,
            nodes: nodes,
            ids: ids,
            edges: edges,
            clusters: clusters,
            labels: labels,
            titles: titles,
            edgeFont: edgeFont,
            titleFont: titleFont,
            spacing: spacing,
            paint: paint,
            hover: hover
        ) else { return nil }

        if canvas.width > Canvas.room(for: paint) / turnBelow, dir == .right || dir == .left {
            let turnedDir: DiagramDirection = dir == .right ? .down : .up
            if let down = drawIn(
                dir: turnedDir,
                nodes: nodes,
                ids: ids,
                edges: edges,
                clusters: clusters,
                labels: labels,
                titles: titles,
                edgeFont: edgeFont,
                titleFont: titleFont,
                spacing: spacing,
                paint: paint,
                hover: hover
            ), down.width < canvas.width {
                canvas = down
                canvas.turned = true
            }
        }
        return canvas
    }

    private static func drawIn(
        dir: DiagramDirection,
        nodes: [DrawNode],
        ids: [String],
        edges: [LayeredEdge],
        clusters: [ClusterSpec],
        labels: [Measured?],
        titles: [Measured],
        edgeFont: TextStyle,
        titleFont: TextStyle,
        spacing: LayeredLayout.Spacing,
        paint: MermaidTheme,
        hover: (MermaidHover, Color)?
    ) -> Canvas? {
        let across = dir == .right || dir == .left
        func ax(_ s: Vec2) -> Vec2 { across ? Vec2(s.y, s.x) : s }
        let flip = dir == .up || dir == .left

        let gEdges: [LayeredLayout.Edge] = zip(edges, labels).map { (e, l) in
            let (from, to) = flip ? (e.to, e.from) : (e.from, e.to)
            return LayeredLayout.Edge(
                from: from,
                to: to,
                label: l.map { ax(ConnectorRenderer.labelBox($0)) },
                minlen: e.minlen
            )
        }
        let gClusters: [LayeredLayout.Cluster] = zip(clusters, titles).map { (s, t) in
            let lead: Float = t.text.isEmpty ? 0.0 : t.size.y + titleInset.y
            let minW: Float = t.text.isEmpty ? 0.0 : t.size.x + 2.0 * titleInset.x
            return LayeredLayout.Cluster(
                parent: s.parent,
                lead: across ? Vec2(lead, 0.0) : Vec2(0.0, lead),
                minSpan: across ? Vec2(0.0, minW) : Vec2(minW, 0.0)
            )
        }
        let graph = LayeredLayout.Graph(
            sizes: nodes.map { ax($0.size) },
            edges: gEdges,
            nodeCluster: nodes.map(\.cluster),
            clusters: gClusters,
            ids: ids
        )
        guard let placed = LayeredLayout.layout(graph, spacing: spacing) else { return nil }
        func pt(_ p: Vec2) -> Vec2 { across ? Vec2(p.y, p.x) : p }

        var c = Canvas()
        c.hover = hover

        func chainOf(_ cOpt: Int?) -> [Int] {
            var v: [Int] = []
            var cur = cOpt
            while let idx = cur {
                if v.count > clusters.count { break }
                v.append(idx)
                cur = clusters[idx].parent
            }
            v.reverse()
            return v
        }

        let clusterBorder = groupBorder(paint)
        var titleBoxes: [(Float, Float, Float, Float)] = []
        let order = (0..<clusters.count).sorted { chainOf($0).count < chainOf($1).count }
        for i in order {
            let b = placed.clusters[i]
            if b == (0, 0, 0, 0) { continue }
            let p0 = pt(Vec2(b.0, b.1))
            let p1 = pt(Vec2(b.2, b.3))
            c.part(.index(.frame, i))
            c.shape(CanvasMath.roundedRect(x0: p0.x, y0: p0.y, x1: p1.x, y1: p1.y, r: 6.0), fill: paint.clusterFill, border: clusterBorder, width: 1.0)
            let at = Vec2((p0.x + p1.x - titles[i].size.x) * 0.5, p0.y + titleInset.y)
            c.labelAt(titles[i], at: at, font: titleFont, color: paint.muted, align: .center)
            if !titles[i].text.isEmpty {
                titleBoxes.append(ConnectorRenderer.titleBox(titles[i], at: at))
            }
        }

        let centers = placed.centers.map(pt)
        let sizes = nodes.map(\.size)
        let ends = edges.map { ($0.from, $0.to) }
        let boxes = labels.map { $0.map { ax(ConnectorRenderer.labelBox($0)) } }
        let onCluster = edges.map(\.onCluster)
        let allChains = (0..<clusters.count).map { chainOf($0) }
        let ctx = RouteCtx(placed: placed, sizes: sizes, shapes: nodes.map(\.shape), labels: boxes, across: across, ends: ends)
            .withTitles(titleBoxes)
            .withClusterEnds(onCluster)
            .withHomes(nodes.map { chainOf($0.cluster) }, chains: allChains)
            .fanned(flip: flip)

        let backs: [Color] = edges.map { e in
            let ca = chainOf(nodes[e.from].cluster)
            let cb = chainOf(nodes[e.to].cluster)
            let common = zip(ca, cb).prefix(while: { $0 == $1 }).count
            var bg = paint.surface
            for _ in 0..<common { bg = overColor(paint.clusterFill, bg) }
            return bg
        }
        ConnectorRenderer.drawEdges(into: &c, ctx: ctx, edges: edges, labels: labels, backs: backs, titles: titleBoxes, flip: flip, font: edgeFont, paint: paint)

        for (i, n) in nodes.enumerated() {
            c.region(i, outline: ShapeRenderer.outline(shape: n.shape, center: centers[i], size: n.size))
            c.part(.index(.node, i))
            drawNode(into: &c, node: n, center: centers[i], paint: paint)
        }
        c.part(nil)
        return c
    }

    private static func drawNode(into c: inout Canvas, node: DrawNode, center ctr: Vec2, paint: MermaidTheme) {
        switch node {
        case .start:
            c.fill(CanvasMath.ellipse(center: ctr, rx: 8.0, ry: 8.0), color: paint.line)
        case .end:
            c.shape(CanvasMath.ellipse(center: ctr, rx: 10.0, ry: 10.0), fill: paint.nodeFill, border: paint.line, width: 1.5)
            c.fill(CanvasMath.ellipse(center: ctr, rx: 5.5, ry: 5.5), color: paint.line)
        case .bar:
            let s = node.size
            c.fill(CanvasMath.roundedRect(x0: ctr.x - s.x * 0.5, y0: ctr.y - s.y * 0.5, x1: ctr.x + s.x * 0.5, y1: ctr.y + s.y * 0.5, r: 2.0), color: paint.line)
        case let .shape(shape, label, size, _, style):
            let resolved = style.resolve(against: paint)
            let start = c.ops.count
            ShapeRenderer.draw(into: &c, shape: shape, label: label, center: ctr, size: size, colors: resolved, paint: paint)
            if let w = style.width {
                for i in start..<c.ops.count {
                    if case let .stroke(pts, closed, width, cap, col) = c.ops[i] {
                        c.ops[i] = .stroke(points: pts, closed: closed, width: width * w, roundCap: cap, color: col)
                    }
                }
            }
        case let .classBox(stereo, name, fields, methods, size, _, style):
            let (fill, border, textColor) = style.resolve(against: paint)
            let x0 = ctr.x - size.x * 0.5, y0 = ctr.y - size.y * 0.5
            let x1 = ctr.x + size.x * 0.5, y1 = ctr.y + size.y * 0.5
            c.shape(CanvasMath.roundedRect(x0: x0, y0: y0, x1: x1, y1: y1, r: 4.0), fill: fill, border: border, width: 1.0)
            var headFont = paint.font; headFont.weight = 600.0
            var memFont = paint.font; memFont.size -= 1.0; memFont.lineHeight = paint.font.resolvedLineHeight - 2.0
            var stereoFont = paint.font; stereoFont.size -= 2.0; stereoFont.lineHeight = paint.font.resolvedLineHeight - 4.0; stereoFont.italic = true
            var y = y0 + 8.0
            if let st = stereo {
                c.label(st, center: Vec2(ctr.x, y + st.size.y * 0.5), font: stereoFont, color: paint.muted, align: .center)
                y += st.size.y + 2.0
            }
            c.label(name, center: Vec2(ctr.x, y + name.size.y * 0.5), font: headFont, color: textColor, align: .center)
            y += name.size.y + 8.0
            for section in [fields, methods] where !section.isEmpty {
                c.stroke([Vec2(x0, y), Vec2(x1, y)], closed: false, width: 1.0, color: border)
                y += 6.0
                for item in section {
                    c.labelAt(item, at: Vec2(x0 + 12.0, y), font: memFont, color: textColor, align: .leading)
                    y += item.size.y + 3.0
                }
                y += 3.0
            }
        case let .entity(name, rows, cols, size, style):
            let (fill, border, textColor) = style.resolve(against: paint)
            let x0 = ctr.x - size.x * 0.5, y0 = ctr.y - size.y * 0.5
            let x1 = ctr.x + size.x * 0.5, y1 = ctr.y + size.y * 0.5
            var headFont = paint.font; headFont.weight = 600.0
            var rowFont = paint.font; rowFont.size -= 1.0; rowFont.lineHeight = paint.font.resolvedLineHeight - 2.0
            let headH = name.size.y + entityPad.y * 2.0
            c.shape(CanvasMath.roundedRect(x0: x0, y0: y0, x1: x1, y1: y1, r: 4.0), fill: fill, border: border, width: 1.0)
            c.label(name, center: Vec2(ctr.x, y0 + headH * 0.5), font: headFont, color: textColor, align: .center)
            var y = y0 + headH
            let stripe = textColor.alpha(0.035)
            for (r, row) in rows.enumerated() {
                let h = entityRowH(row)
                if r % 2 == 1 {
                    c.fill([Vec2(x0 + 0.5, y), Vec2(x1 - 0.5, y), Vec2(x1 - 0.5, y + h), Vec2(x0 + 0.5, y + h)], color: stripe)
                }
                c.stroke([Vec2(x0, y), Vec2(x1, y)], closed: false, width: r == 0 ? 1.0 : 0.5, color: r == 0 ? border : border.alpha(0.5))
                var x = x0
                for (i, (cell, w)) in zip(row, cols).enumerated() {
                    let color = i >= 2 ? paint.muted : textColor
                    c.labelAt(cell, at: Vec2(x + entityPad.x, y + (h - cell.size.y) * 0.5), font: rowFont, color: color, align: .leading)
                    x += w
                }
                y += h
            }
        case let .card(shape, lines, size, _, colors, person):
            ShapeRenderer.draw(into: &c, shape: shape, label: .empty, center: ctr, size: size, colors: colors, paint: paint)
            let cap = shape == .cylinder ? ShapeRenderer.rim(size.x) : 0.0
            let glyph: Float = person ? personHeight : 0.0
            let total = glyph + lines.reduce(Float(0)) { $0 + $1.0.size.y + 3.0 } - 3.0
            var y = ctr.y - total * 0.5 + cap * 0.5
            if person {
                c.fill(CanvasMath.ellipse(center: Vec2(ctr.x, y + 6.0), rx: 6.0, ry: 6.0), color: colors.2)
                c.fill(CanvasMath.arc(center: Vec2(ctr.x, y + 23.0), rx: 11.0, ry: 8.5, a0: 180.0, a1: 360.0, steps: 16), color: colors.2)
                y += glyph
            }
            for (m, font) in lines {
                c.label(m, center: Vec2(ctr.x, y + m.size.y * 0.5), font: font, color: colors.2, align: .center)
                y += m.size.y + 3.0
            }
        }
    }

    static let personHeight: Float = 30.0

    static func classBox(
        stereo: String?,
        name: String,
        fields: [String],
        methods: [String],
        cluster: Int?,
        style: NodeStyle,
        paint: MermaidTheme
    ) -> DrawNode {
        var headFont = paint.font; headFont.weight = 600.0
        var memFont = paint.font; memFont.size -= 1.0; memFont.lineHeight = paint.font.resolvedLineHeight - 2.0
        var stereoFont = paint.font; stereoFont.size -= 2.0; stereoFont.lineHeight = paint.font.resolvedLineHeight - 4.0; stereoFont.italic = true

        let stM = stereo.map { measureWrap("«\($0)»", font: stereoFont, maxWidth: 240.0) }
        let nameM = measureWrap(name, font: headFont, maxWidth: 240.0)
        let fieldMs = fields.map { measureWrap($0, font: memFont, maxWidth: 240.0) }
        let methodMs = methods.map { measureWrap($0, font: memFont, maxWidth: 240.0) }
        var w = max(nameM.size.x, stM?.size.x ?? 0.0)
        for m in fieldMs + methodMs { w = max(w, m.size.x) }
        let totalW = max(w + 26.0, 84.0)
        var h: Float = 16.0 + nameM.size.y + (stM.map { $0.size.y + 2.0 } ?? 0.0)
        for sec in [fieldMs, methodMs] where !sec.isEmpty {
            h += 9.0 + sec.reduce(Float(0)) { $0 + $1.size.y + 3.0 }
        }
        return .classBox(stereo: stM, name: nameM, fields: fieldMs, methods: methodMs, size: Vec2(totalW, max(h, 38.0)), cluster: cluster, style: style)
    }

    static func entityRowH(_ row: [Measured]) -> Float {
        (row.map(\.size.y).max() ?? 0.0) + entityPad.y * 2.0
    }
}
