import Foundation
import Rune

struct SankeyDiagram: Sendable {
    var nodes: [String] = []
    var links: [(Int, Int, Float)] = []
    var title: String? = nil
}

enum SankeyParser {
    private static let height: Float = 300.0
    private static let nodeWidth: Float = 10.0
    private static let pad: Float = 12.0

    static func parse(_ body: [String]) -> SankeyDiagram? {
        var s = SankeyDiagram()
        var ids: [String: Int] = [:]

        func nodeIndex(_ name: String) -> Int {
            if let existing = ids[name] { return existing }
            let next = s.nodes.count
            s.nodes.append(name)
            ids[name] = next
            return next
        }

        for l in body {
            let f = parseFields(l)
            guard f.count >= 3,
                  let v = Float(f[2].trimmingCharacters(in: .whitespaces)),
                  v.isFinite, v >= 0.0 else { continue }
            let a = clean(f[0])
            let b = clean(f[1])
            if a.isEmpty || b.isEmpty || a == b { continue }
            let from = nodeIndex(a)
            let to = nodeIndex(b)
            s.links.append((from, to, v))
            if s.nodes.count + s.links.count > MermaidLimits.maxItems { return nil }
        }
        return s.links.isEmpty ? nil : s
    }

    private static func parseFields(_ l: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var idx = l.startIndex
        while idx < l.endIndex {
            let ch = l[idx]
            let next = l.index(after: idx)
            if ch == "\"" && quoted && next < l.endIndex && l[next] == "\"" {
                cur.append("\"")
                idx = l.index(after: next)
                continue
            }
            if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                out.append(cur)
                cur.removeAll(keepingCapacity: true)
            } else {
                cur.append(ch)
            }
            idx = next
        }
        out.append(cur)
        return out
    }

    static func columns(_ s: SankeyDiagram) -> [Int] {
        let n = s.nodes.count
        var depth = Array(repeating: 0, count: n)
        for _ in 0..<n {
            var moved = false
            for (a, b, _) in s.links {
                if depth[b] < depth[a] + 1 && depth[a] + 1 < n {
                    depth[b] = depth[a] + 1
                    moved = true
                }
            }
            if !moved { break }
        }
        let last = depth.max() ?? 0
        for i in 0..<n {
            if !s.links.contains(where: { $0.0 == i }) {
                depth[i] = last
            }
        }
        return depth
    }

    static func draw(_ s: SankeyDiagram, paint: MermaidTheme) -> MermaidScene? {
        let n = s.nodes.count
        let note = MermaidChart.small(paint)
        let col = columns(s)
        let cols = (col.max() ?? 0) + 1
        var ins = Array(repeating: Float(0.0), count: n)
        var outs = Array(repeating: Float(0.0), count: n)
        for (a, b, v) in s.links {
            outs[a] += v
            ins[b] += v
        }
        let value = (0..<n).map { max(ins[$0], outs[$0]) }
        let members = (0..<cols).map { c in (0..<n).filter { col[$0] == c } }
        var ky = Float.greatestFiniteMagnitude
        for m in members {
            let sumV = max(m.reduce(Float(0.0)) { $0 + value[$1] }, 1e-6)
            let avail = height - pad * Float(max(m.count - 1, 0))
            ky = min(ky, avail / sumV)
        }
        ky = max(ky, 0.0)
        let h = value.map { max($0 * ky, 1.0) }

        var y = Array(repeating: Float(0.0), count: n)
        func stack(_ m: [Int]) {
            let total = m.reduce(Float(0.0)) { $0 + h[$1] } + pad * Float(max(m.count - 1, 0))
            var at = (height - total) * 0.5
            for i in m {
                y[i] = at
                at += h[i] + pad
            }
        }

        var order = members
        for m in order { stack(m) }
        for pass in 0..<4 {
            let forward = pass % 2 == 0
            for cIdx in 0..<cols {
                let colIdx = forward ? cIdx : (cols - 1 - cIdx)
                func mid(_ i: Int) -> Float {
                    var sum: Float = 0.0
                    var w: Float = 0.0
                    for (a, b, v) in s.links {
                        let other: Int?
                        if b == i && forward { other = a }
                        else if a == i && !forward { other = b }
                        else { other = nil }
                        if let o = other {
                            sum += (y[o] + h[o] * 0.5) * v
                            w += v
                        }
                    }
                    return w > 0.0 ? (sum / w) : (y[i] + h[i] * 0.5)
                }
                let keyed = order[colIdx].map { ($0, mid($0)) }.sorted { $0.1 < $1.1 }
                order[colIdx] = keyed.map(\.0)
                stack(order[colIdx])
            }
        }

        let width = Canvas.room(for: paint)
        func xOf(_ cIdx: Int) -> Float {
            cols == 1 ? 0.0 : Float(cIdx) * (width - nodeWidth) / Float(cols - 1)
        }

        var c = Canvas()
        var linkIndices = Array(s.links.indices)
        linkIndices.sort { y[s.links[$0].1] < y[s.links[$1].1] }
        var outAt = y
        var inAt = y
        var ends = Array(repeating: (Float(0.0), Float(0.0)), count: s.links.count)
        for k in linkIndices {
            let (a, _, v) = s.links[k]
            ends[k].0 = outAt[a]
            outAt[a] += v * ky
        }
        linkIndices.sort { y[s.links[$0].0] < y[s.links[$1].0] }
        for k in linkIndices {
            let (_, b, v) = s.links[k]
            ends[k].1 = inAt[b]
            inAt[b] += v * ky
        }

        for (k, (a, b, v)) in s.links.enumerated() {
            let t = max(v * ky, 0.5)
            let sx = xOf(col[a]) + nodeWidth
            let tx = xOf(col[b])
            var band = MermaidChart.sCurve(Vec2(sx, ends[k].0), Vec2(tx, ends[k].1), upright: false)
            band.append(contentsOf: MermaidChart.sCurve(Vec2(tx, ends[k].1 + t), Vec2(sx, ends[k].0 + t), upright: false))
            c.fill(band, color: MermaidChart.solid(paint, hue: MermaidChart.hue(a)).alpha(0.42))
        }

        for i in 0..<n {
            let x = xOf(col[i])
            c.fill([Vec2(x, y[i]), Vec2(x + nodeWidth, y[i]), Vec2(x + nodeWidth, y[i] + h[i]), Vec2(x, y[i] + h[i])], color: MermaidChart.solid(paint, hue: MermaidChart.hue(i)))
            let m = measureText("\(s.nodes[i]) \(PieParser.formatNumber(Double(value[i])))", font: note)
            let mid = y[i] + h[i] * 0.5 - m.size.y * 0.5
            if col[i] + 1 == cols && cols > 1 {
                c.labelAt(m, at: Vec2(x - 6.0 - m.size.x, mid), font: note, color: paint.text, align: .trailing)
            } else {
                c.labelAt(m, at: Vec2(x + nodeWidth + 6.0, mid), font: note, color: paint.text, align: .leading)
            }
        }
        return c.finishFitMutating(paint: paint)
    }
}
