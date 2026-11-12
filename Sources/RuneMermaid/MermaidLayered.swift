import Foundation
import Rune

/// Sugiyama layered graph layout (`rune_mermaid::layered`).
enum LayeredLayout {
    static let maxMinlen = 8
    private static let maxDummies = 3000

    struct Graph {
        var sizes: [Vec2]
        var edges: [Edge]
        var nodeCluster: [Int?]
        var clusters: [Cluster]
        var ids: [String] = []
    }

    struct Edge {
        var from: Int
        var to: Int
        var label: Vec2?
        var minlen: Int
    }

    struct Cluster {
        var parent: Int?
        var lead: Vec2
        var minSpan: Vec2
    }

    struct Spacing {
        var node: Float
        var rank: Float
        var cluster: Float
    }

    struct Placed {
        var centers: [Vec2]
        var paths: [[Vec2]]
        var labels: [Vec2?]
        var clusters: [(Float, Float, Float, Float)]
    }

    private enum NodeKind: Equatable {
        case real(Int)
        case dummy(Int, Bool)

        var isDummyWithLabel: Bool {
            if case let .dummy(_, hasLabel) = self { return hasLabel }
            return false
        }

        var isReal: Bool {
            if case .real = self { return true }
            return false
        }
    }

    private struct LNode {
        var kind: NodeKind
        var rank: Int
        var size: Vec2
        var cluster: Int?
        var preds: [Int] = []
        var succs: [Int] = []
    }

    static func layout(_ g: Graph, spacing sp: Spacing) -> Placed? {
        let n = g.sizes.count
        var chains: [[Int]] = []
        chains.reserveCapacity(g.clusters.count)
        for c in 0..<g.clusters.count {
            var v: [Int] = []
            var cur: Int? = c
            while let idx = cur {
                if v.count > g.clusters.count { break }
                v.append(idx)
                cur = g.clusters[idx].parent
            }
            v.reverse()
            chains.append(v)
        }
        func chainOf(_ c: Int?) -> [Int] {
            c.map { chains[$0] } ?? []
        }

        // 1. Break cycles via DFS back-edge reversal.
        var out: [[Int]] = Array(repeating: [], count: n)
        for (i, e) in g.edges.enumerated() where e.from != e.to {
            out[e.from].append(i)
        }
        var reversed = Array(repeating: false, count: g.edges.count)
        var state = Array(repeating: 0, count: n)
        for root in 0..<n where state[root] == 0 {
            var stack: [(Int, Int)] = [(root, 0)]
            state[root] = 1
            while !stack.isEmpty {
                let topIdx = stack.count - 1
                let v = stack[topIdx].0
                let k = stack[topIdx].1
                if k < out[v].count {
                    stack[topIdx].1 = k + 1
                    let e = out[v][k]
                    let w = g.edges[e].to
                    if state[w] == 0 {
                        state[w] = 1
                        stack.append((w, 0))
                    } else if state[w] == 1 {
                        reversed[e] = true
                    }
                } else {
                    state[v] = 2
                    stack.removeLast()
                }
            }
        }

        func ends(_ i: Int) -> (Int, Int) {
            let e = g.edges[i]
            return reversed[i] ? (e.to, e.from) : (e.from, e.to)
        }
        let live = (0..<g.edges.count).filter { g.edges[$0].from != g.edges[$0].to }

        // 2. Ranks, doubled so edge labels get their own rank.
        func span(_ i: Int) -> Int {
            2 * min(max(g.edges[i].minlen, 1), maxMinlen)
        }
        var indeg = Array(repeating: 0, count: n)
        var succ: [[Int]] = Array(repeating: [], count: n)
        var pred: [[Int]] = Array(repeating: [], count: n)
        for i in live {
            let (a, b) = ends(i)
            indeg[b] += 1
            succ[a].append(i)
            pred[b].append(i)
        }
        var topo: [Int] = []
        topo.reserveCapacity(n)
        var ready = (0..<n).filter { indeg[$0] == 0 }.reversed().map { $0 }
        while let v = ready.popLast() {
            topo.append(v)
            for i in succ[v].reversed() {
                let b = ends(i).1
                indeg[b] -= 1
                if indeg[b] == 0 {
                    ready.append(b)
                }
            }
        }
        for v in 0..<n where !topo.contains(v) {
            topo.append(v)
        }
        var rank = Array(repeating: 0, count: n)
        for v in topo {
            for i in pred[v] {
                rank[v] = max(rank[v], rank[ends(i).0] + span(i))
            }
        }
        for v in topo.reversed() {
            if pred[v].isEmpty && !succ[v].isEmpty {
                rank[v] = succ[v].map { rank[ends($0).1] - span($0) }.min() ?? rank[v]
            }
        }

        // 3. Layered graph with dummy nodes.
        var dummies = 0
        for i in live {
            let (a, b) = ends(i)
            if rank[b] > rank[a] + 1 {
                dummies += rank[b] - (rank[a] + 1)
            }
        }
        if dummies > maxDummies { return nil }

        var nodes: [LNode] = (0..<n).map { v in
            LNode(kind: .real(v), rank: rank[v], size: g.sizes[v], cluster: g.nodeCluster[v])
        }
        var edgeChain: [[Int]] = Array(repeating: [], count: g.edges.count)
        for i in live {
            let (a, b) = ends(i)
            let ca = chainOf(g.nodeCluster[a])
            let cb = chainOf(g.nodeCluster[b])
            let common = zip(ca, cb).prefix(while: { $0 == $1 }).count
            let cluster: Int? = common > 0 ? ca[common - 1] : nil
            let mid = rank[a] + (rank[b] - rank[a]) / 2
            var prev = a
            var chain = [a]
            if rank[a] + 1 < rank[b] {
                for r in (rank[a] + 1)..<rank[b] {
                    let lbl = r == mid ? g.edges[i].label : nil
                    let id = nodes.count
                    nodes.append(LNode(
                        kind: .dummy(i, lbl != nil),
                        rank: r,
                        size: lbl ?? .zero,
                        cluster: cluster,
                        preds: [prev]
                    ))
                    nodes[prev].succs.append(id)
                    chain.append(id)
                    prev = id
                }
            }
            nodes[prev].succs.append(b)
            nodes[b].preds.append(prev)
            chain.append(b)
            edgeChain[i] = chain
        }
        let ranks = (nodes.map(\.rank).max() ?? -1) + 1
        guard ranks > 0 else {
            return Placed(centers: [], paths: [], labels: [], clusters: Array(repeating: (0, 0, 0, 0), count: g.clusters.count))
        }

        // 4. Order within layers: DFS start + barycenter sweeps.
        var layers: [[Int]] = Array(repeating: [], count: ranks)
        var seen = Array(repeating: false, count: nodes.count)
        for root in 0..<n {
            var stack = [root]
            while let v = stack.popLast() {
                if seen[v] { continue }
                seen[v] = true
                layers[nodes[v].rank].append(v)
                stack.append(contentsOf: nodes[v].succs.reversed())
            }
        }
        for (v, s) in seen.enumerated() where !s {
            layers[nodes[v].rank].append(v)
        }
        let nodeChains = nodes.map { chainOf($0.cluster) }
        for r in 0..<layers.count {
            let keys = (0..<layers[r].count).map { Float($0) }
            layers[r] = groupedOrder(layers[r], keys: keys, chains: nodeChains)
        }
        let parents = g.clusters.map(\.parent)
        alignClusters(&layers, chains: nodeChains, parents: parents)
        var best = layers
        var bestX = crossings(layers, nodes: nodes)
        for it in 0..<16 {
            if bestX == 0 { break }
            let down = it % 2 == 0
            let order: [Int] = down ? Array(1..<ranks) : Array((0..<max(0, ranks - 1)).reversed())
            var pos = positions(layers, count: nodes.count)
            for r in order {
                let layer = layers[r]
                let keys: [Float] = layer.enumerated().map { (i, v) in
                    let nb = down ? nodes[v].preds : nodes[v].succs
                    if nb.isEmpty { return Float(i) }
                    return nb.reduce(Float(0)) { $0 + Float(pos[$1]) } / Float(nb.count)
                }
                layers[r] = groupedOrder(layer, keys: keys, chains: nodeChains)
                for (i, v) in layers[r].enumerated() {
                    pos[v] = i
                }
            }
            alignClusters(&layers, chains: nodeChains, parents: parents)
            let x = crossings(layers, nodes: nodes)
            if x < bestX {
                bestX = x
                best = layers
            }
        }
        layers = best

        // 5. Positions along layers via alternating weighted isotonic regressions.
        let seps: [[Float]] = layers.map { layer in
            guard layer.count >= 2 else { return [] }
            return (0..<(layer.count - 1)).map { idx in
                let v0 = layer[idx], v1 = layer[idx + 1]
                let a = nodes[v0], b = nodes[v1]
                let aReal = a.kind.isReal || a.kind.isDummyWithLabel
                let bReal = b.kind.isReal || b.kind.isDummyWithLabel
                let gap = (aReal && bReal) ? sp.node : sp.node * 0.5
                let ca = nodeChains[v0], cb = nodeChains[v1]
                let common = zip(ca, cb).prefix(while: { $0 == $1 }).count
                let closing = Float(ca.count - common) * sp.cluster
                let opening = cb[common...].reduce(Float(0)) { $0 + sp.cluster + g.clusters[$1].lead.x }
                return (a.size.x + b.size.x) * 0.5 + gap + closing + opening
            }
        }
        var x = Array(repeating: Float(0), count: nodes.count)
        for (layer, sep) in zip(layers, seps) {
            var at: Float = 0
            for (i, v) in layer.enumerated() {
                if i > 0 { at += sep[i - 1] }
                x[v] = at
            }
        }
        for it in 0..<24 {
            let usePreds = it % 3 != 1
            let useSuccs = it % 3 != 0
            let order: [Int] = it % 2 == 0 ? Array(0..<ranks) : Array((0..<ranks).reversed())
            for r in order {
                let layer = layers[r]
                var want: [Float] = []
                var w: [Float] = []
                want.reserveCapacity(layer.count)
                w.reserveCapacity(layer.count)
                for v in layer {
                    let node = nodes[v]
                    var nb: [Int] = []
                    if usePreds { nb.append(contentsOf: node.preds) }
                    if useSuccs { nb.append(contentsOf: node.succs) }
                    if nb.isEmpty {
                        want.append(x[v])
                        w.append(0.1)
                    } else {
                        let mean = nb.reduce(Float(0)) { $0 + x[$1] } / Float(nb.count)
                        let nodeW: Float = node.kind.isReal ? 1.0 : 4.0
                        want.append(mean)
                        w.append(nodeW * Float(nb.count))
                    }
                }
                let placed = isotonic(want: want, weights: w, sep: seps[r])
                for (v, p) in zip(layer, placed) {
                    x[v] = p
                }
            }
        }

        // 6. Layer depths.
        var first = Array(repeating: Int.max, count: g.clusters.count)
        var last = Array(repeating: 0, count: g.clusters.count)
        for v in 0..<n {
            for c in nodeChains[v] {
                first[c] = min(first[c], nodes[v].rank)
                last[c] = max(last[c], nodes[v].rank)
            }
        }
        let heights = layers.map { layer in layer.map { nodes[$0].size.y }.max() ?? 0.0 }
        var y = Array(repeating: Float(0), count: ranks)
        var atY: Float = 0.0
        for r in 0..<ranks {
            let opening = (0..<g.clusters.count)
                .filter { first[$0] == r }
                .reduce(Float(0)) { $0 + sp.cluster + g.clusters[$1].lead.y }
            if r > 0 {
                let closing = Float((0..<g.clusters.count).filter { last[$0] == r - 1 && first[$0] != Int.max }.count) * sp.cluster
                atY += heights[r - 1] * 0.5 + sp.rank * 0.5 + closing
            }
            atY += opening
            if r > 0 || opening > 0.0 {
                atY += heights[r] * 0.5
            } else {
                atY = heights[0] * 0.5
            }
            y[r] = atY
        }

        func drawn(_ v: Int) -> Bool {
            nodes[v].kind.isReal || nodes[v].kind.isDummyWithLabel
        }
        func slide(_ v: Int) -> Float {
            nodes[v].kind.isReal ? nodes[v].size.x * 0.25 : 0.0
        }
        let baseY = y
        var grown: Float = 0.0
        for r in 1..<ranks {
            var need: Float = 0.0
            for v in layers[r] where drawn(v) {
                for u in nodes[v].preds where drawn(u) {
                    let dx = abs(x[u] - x[v]) - slide(u) - slide(v)
                    let dy = (baseY[r] - nodes[v].size.y * 0.5) - (baseY[r - 1] + nodes[u].size.y * 0.5)
                    need = max(need, 2.0 * dx - dy)
                }
            }
            grown += min(max(need, 0.0), sp.rank)
            y[r] += grown
        }

        // 7. Cluster boxes.
        let depthOrder = (0..<g.clusters.count).sorted { chains[$0].count > chains[$1].count }
        func nodeRect(_ xs: [Float], _ v: Int) -> (Float, Float, Float, Float) {
            let cx = xs[v]
            let cy = y[nodes[v].rank]
            let sz = nodes[v].size
            return (cx - sz.x * 0.5, cy - sz.y * 0.5, cx + sz.x * 0.5, cy + sz.y * 0.5)
        }
        func boxesOf(_ xs: [Float]) -> [(Float, Float, Float, Float)] {
            var boxes = Array(repeating: (Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude), count: g.clusters.count)
            for (v, node) in nodes.enumerated() {
                if (node.kind.isReal || node.kind.isDummyWithLabel), let c = node.cluster {
                    let r = nodeRect(xs, v)
                    let b = boxes[c]
                    boxes[c] = (min(b.0, r.0), min(b.1, r.1), max(b.2, r.2), max(b.3, r.3))
                }
            }
            for c in depthOrder {
                let b = boxes[c]
                if b.0 > b.2 { continue }
                let lead = g.clusters[c].lead
                let minSpan = g.clusters[c].minSpan
                var p0 = b.0 - sp.cluster - lead.x
                var p1 = b.1 - sp.cluster - lead.y
                var p2 = b.2 + sp.cluster
                var p3 = b.3 + sp.cluster
                let curW = p2 - p0
                if curW < minSpan.x {
                    let extra = (minSpan.x - curW) * 0.5
                    p0 -= extra
                    p2 += extra
                }
                let curH = p3 - p1
                if curH < minSpan.y {
                    let extra = (minSpan.y - curH) * 0.5
                    p1 -= extra
                    p3 += extra
                }
                boxes[c] = (p0, p1, p2, p3)
                if let p = g.clusters[c].parent {
                    let pb = boxes[p]
                    boxes[p] = (min(pb.0, p0), min(pb.1, p1), max(pb.2, p2), max(pb.3, p3))
                }
            }
            return boxes
        }

        // 8. Push overlapping sibling clusters and loose nodes apart.
        let members: [[Int]] = (0..<g.clusters.count).map { c in
            (0..<nodes.count).filter { nodeChains[$0].contains(c) }
        }
        let pos = positions(layers, count: nodes.count)
        let firstOnRank: [[Int: Int]] = members.map { m in
            var at: [Int: Int] = [:]
            for v in m where at[nodes[v].rank] == nil {
                at[nodes[v].rank] = v
            }
            return at
        }
        enum Item {
            case cluster(Int)
            case node(Int)
            var isNode: Bool {
                if case .node = self { return true }
                return false
            }
        }
        func itemNodes(_ it: Item) -> [Int] {
            switch it {
            case let .cluster(c): members[c]
            case let .node(v): [layers[nodes[v].rank][pos[v]]]
            }
        }
        func onRank(_ it: Item, _ r: Int) -> Int? {
            switch it {
            case let .cluster(c): firstOnRank[c][r]
            case let .node(v): nodes[v].rank == r ? v : nil
            }
        }
        func leftOf(_ a: Item, _ b: Item, _ ba: (Float, Float, Float, Float), _ bb: (Float, Float, Float, Float)) -> Bool {
            for u in itemNodes(a) {
                if let w = onRank(b, nodes[u].rank) {
                    return pos[u] < pos[w]
                }
            }
            return ba.0 + ba.2 <= bb.0 + bb.2
        }

        for _ in 0..<12 {
            let boxes = boxesOf(x)
            var items: [(Int?, Item, (Float, Float, Float, Float))] = []
            for c in 0..<g.clusters.count where boxes[c].0 <= boxes[c].2 {
                items.append((g.clusters[c].parent, .cluster(c), boxes[c]))
            }
            for v in 0..<n {
                items.append((g.nodeCluster[v], .node(v), nodeRect(x, v)))
            }
            var shift = Array(repeating: Float(0), count: nodes.count)
            var moved = false
            for i in 0..<items.count {
                for j in (i + 1)..<items.count {
                    let (pa, a, ba) = items[i]
                    let (pb, b, bb) = items[j]
                    if pa != pb || (a.isNode && b.isNode) || ba.1 >= bb.3 || bb.1 >= ba.3 {
                        continue
                    }
                    let ((l, bl), (r, br)) = leftOf(a, b, ba, bb) ? ((a, ba), (b, bb)) : ((b, bb), (a, ba))
                    let d = bl.2 + sp.node * 0.5 - br.0
                    if d > 0.5 {
                        for v in itemNodes(l) { shift[v] -= d * 0.5 }
                        for v in itemNodes(r) { shift[v] += d * 0.5 }
                        moved = true
                    }
                }
            }
            for (c, b) in boxes.enumerated() where b.0 <= b.2 {
                let nearLo = max(0, first[c] - 1)
                let nearHi = last[c] + 1
                for v in n..<nodes.count {
                    guard case let .dummy(e, _) = nodes[v].kind else { continue }
                    let (a, z) = ends(e)
                    if !(nearLo...nearHi).contains(nodes[v].rank) || nodeChains[a].contains(c) || nodeChains[z].contains(c) {
                        continue
                    }
                    let lo = b.0 - sp.node * 0.5
                    let hi = b.2 + sp.node * 0.5
                    if x[v] <= lo || x[v] >= hi { continue }
                    let isLeft: Bool
                    if let w = firstOnRank[c][nodes[v].rank] {
                        isLeft = pos[v] < pos[w]
                    } else {
                        isLeft = x[v] < (b.0 + b.2) * 0.5
                    }
                    shift[v] += isLeft ? (lo - x[v]) : (hi - x[v])
                    moved = true
                }
            }
            if !moved { break }
            for i in 0..<nodes.count { x[i] += shift[i] }
            for (layer, sep) in zip(layers, seps) {
                let want = layer.map { x[$0] }
                let placed = isotonic(want: want, weights: Array(repeating: 1.0, count: layer.count), sep: sep)
                for (v, p) in zip(layer, placed) { x[v] = p }
            }
        }
        let boxes = boxesOf(x)

        // 9. Normalize to origin.
        var loX = Float.greatestFiniteMagnitude
        var loY = Float.greatestFiniteMagnitude
        for (v, node) in nodes.enumerated() {
            loX = min(loX, x[v] - node.size.x * 0.5)
            loY = min(loY, y[node.rank] - node.size.y * 0.5)
        }
        for b in boxes where b.0 <= b.2 {
            loX = min(loX, b.0)
            loY = min(loY, b.1)
        }
        if loX == Float.greatestFiniteMagnitude {
            loX = 0.0
            loY = 0.0
        }
        func at(_ v: Int) -> Vec2 {
            Vec2(x[v] - loX, y[nodes[v].rank] - loY)
        }
        let centers = (0..<n).map(at)
        var paths: [[Vec2]] = []
        var labels: [Vec2?] = []
        paths.reserveCapacity(g.edges.count)
        labels.reserveCapacity(g.edges.count)
        for (i, e) in g.edges.enumerated() {
            if e.from == e.to {
                paths.append([at(e.from)])
                labels.append(nil)
                continue
            }
            var pts = edgeChain[i].map(at)
            let lbl = edgeChain[i].first(where: { nodes[$0].kind.isDummyWithLabel }).map(at)
            labels.append(lbl)
            if reversed[i] { pts.reverse() }
            paths.append(pts)
        }
        let clusters = boxes.map { b in
            b.0 <= b.2 ? (b.0 - loX, b.1 - loY, b.2 - loX, b.3 - loY) : (0, 0, 0, 0)
        }
        return Placed(centers: centers, paths: paths, labels: labels, clusters: clusters)
    }

    private static func positions(_ layers: [[Int]], count: Int) -> [Int] {
        var pos = Array(repeating: 0, count: count)
        for layer in layers {
            for (i, v) in layer.enumerated() {
                pos[v] = i
            }
        }
        return pos
    }

    private static func groupedOrder(_ layer: [Int], keys: [Float], chains: [[Int]]) -> [Int] {
        grouped(layer, keys: keys, chains: chains, rank: nil)
    }

    private static func grouped(_ layer: [Int], keys: [Float], chains: [[Int]], rank: [Float]?) -> [Int] {
        func go(_ items: [(Int, Float)], depth: Int) -> [(Int, Float)] {
            var groups: [(Int?, [(Int, Float)])] = []
            for it in items {
                let c: Int? = depth < chains[it.0].count ? chains[it.0][depth] : nil
                if let idx = groups.firstIndex(where: { c != nil && $0.0 == c }) {
                    groups[idx].1.append(it)
                } else {
                    groups.append((c, [it]))
                }
            }
            var keyed: [(Float, Int?, [(Int, Float)])] = groups.map { (c, members) in
                let key = members.reduce(Float(0)) { $0 + $1.1 } / Float(members.count)
                let sortedMembers = c != nil ? go(members, depth: depth + 1) : members
                return (key, c, sortedMembers)
            }
            keyed.sort { $0.0 < $1.0 }
            if let rank {
                let slots = (0..<keyed.count).filter { keyed[$0].1 != nil }
                var held = slots.map { (keyed[$0].1 ?? 0, keyed[$0].2) }
                held.sort { rank[$0.0] < rank[$1.0] }
                for (i, pair) in zip(slots, held) {
                    keyed[i].1 = pair.0
                    keyed[i].2 = pair.1
                }
            }
            return keyed.flatMap(\.2)
        }
        let items = Array(zip(layer, keys))
        return go(items, depth: 0).map(\.0)
    }

    private static func alignClusters(_ layers: inout [[Int]], chains: [[Int]], parents: [Int?]) {
        let k = parents.count
        if k < 2 { return }
        var lead = Array(repeating: Array(repeating: 0, count: k), count: k)
        var meanSum = Array(repeating: Float(0), count: k)
        var meanCount = Array(repeating: 0, count: k)
        for layer in layers {
            var first: [Int?] = Array(repeating: nil, count: k)
            for (i, v) in layer.enumerated() {
                for c in chains[v] {
                    if first[c] == nil { first[c] = i }
                    meanSum[c] += Float(i) / Float(max(layer.count, 1))
                    meanCount[c] += 1
                }
            }
            for a in 0..<k {
                for b in 0..<k {
                    if let ia = first[a], let ib = first[b], ia < ib, parents[a] == parents[b] {
                        lead[a][b] += 1
                        lead[b][a] -= 1
                    }
                }
            }
        }
        let rank: [Float] = (0..<k).map { c in
            let neg = (0..<k).filter { lead[c][$0] < 0 }.count
            let pos = (0..<k).filter { lead[c][$0] > 0 }.count
            let behind = Float(neg - pos)
            return behind + 0.5 * meanSum[c] / Float(max(meanCount[c], 1))
        }
        for r in 0..<layers.count {
            let keys = (0..<layers[r].count).map { Float($0) }
            layers[r] = grouped(layers[r], keys: keys, chains: chains, rank: rank)
        }
    }

    private static func crossings(_ layers: [[Int]], nodes: [LNode]) -> Int {
        let pos = positions(layers, count: nodes.count)
        var total = 0
        for layer in layers {
            var edges: [(Int, Int)] = []
            for v in layer {
                for w in nodes[v].succs {
                    edges.append((pos[v], pos[w]))
                }
            }
            for i in 0..<edges.count {
                let a = edges[i]
                for j in (i + 1)..<edges.count {
                    let b = edges[j]
                    if (a.0 < b.0 && a.1 > b.1) || (a.0 > b.0 && a.1 < b.1) {
                        total += 1
                    }
                }
            }
        }
        return total
    }

    static func isotonic(want: [Float], weights: [Float], sep: [Float]) -> [Float] {
        var offset: [Float] = []
        offset.reserveCapacity(want.count)
        var at: Float = 0
        for i in 0..<want.count {
            if i > 0 { at += sep[i - 1] }
            offset.append(at)
        }
        var blocks: [(mean: Float, weight: Float, count: Int)] = []
        for i in 0..<want.count {
            var b = (mean: want[i] - offset[i], weight: max(weights[i], 1e-3), count: 1)
            while let prev = blocks.last {
                if prev.mean <= b.mean { break }
                blocks.removeLast()
                let total = prev.weight + b.weight
                b = ((prev.mean * prev.weight + b.mean * b.weight) / total, total, prev.count + b.count)
            }
            blocks.append(b)
        }
        var out: [Float] = []
        out.reserveCapacity(want.count)
        for b in blocks {
            for _ in 0..<b.count {
                let i = out.count
                out.append(b.mean + offset[i])
            }
        }
        return out
    }
}
