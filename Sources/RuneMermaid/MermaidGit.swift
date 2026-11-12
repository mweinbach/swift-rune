import Foundation
import Rune

struct GitCommit: Sendable {
    enum Kind: Sendable, Equatable {
        case normal
        case reverse
        case highlight
        case merge
        case cherryPick
    }

    var id: String?
    var tag: String?
    var kind: Kind
    var branch: Int
    var parents: [Int]
    var picked: Int?
}

struct GitBranch: Sendable {
    var name: String
    var order: Float?
}

struct GitGraphDiagram: Sendable {
    enum Flow: Sendable, Equatable {
        case right
        case down
        case up
    }

    var flow: Flow
    var branches: [GitBranch]
    var commits: [GitCommit]
}

enum GitParser {
    private static let radius: Float = 9.0
    private static let step: Float = 44.0
    private static let padX: Float = 6.0
    private static let padY: Float = 2.0

    static func parse(header: String, body: [String]) -> GitGraphDiagram? {
        let h = header.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let flow: GitGraphDiagram.Flow
        switch h {
        case "TB", "TD": flow = .down
        case "BT": flow = .up
        default: flow = .right
        }
        var g = GitGraphDiagram(flow: flow, branches: [GitBranch(name: "main", order: nil)], commits: [])
        var heads: [Int?] = [nil]
        var cur = 0

        for line in body {
            for stmt in statements(line) {
                let cmd: String
                let rest: String
                if let ws = stmt.firstIndex(where: \.isWhitespace) {
                    cmd = String(stmt[..<ws])
                    rest = String(stmt[ws...]).trimmingCharacters(in: .whitespaces)
                } else {
                    cmd = stmt
                    rest = ""
                }
                if g.commits.count + g.branches.count > MermaidLimits.maxItems { return nil }
                func findBranch(_ name: String) -> Int? {
                    g.branches.firstIndex { $0.name == name }
                }

                switch cmd {
                case "commit":
                    let a = parseAttrs(rest)
                    let kind = parseKind(a) ?? .normal
                    let parents = heads[cur].map { [$0] } ?? []
                    g.commits.append(GitCommit(id: getAttr(a, "id"), tag: getAttr(a, "tag"), kind: kind, branch: cur, parents: parents, picked: nil))
                    heads[cur] = g.commits.count - 1
                case "branch":
                    let (bName, tail) = parseName(rest)
                    if bName.isEmpty || findBranch(bName) != nil { continue }
                    let order = getAttr(parseAttrs(tail), "order").flatMap(Float.init).flatMap { $0.isFinite ? $0 : nil }
                    g.branches.append(GitBranch(name: bName, order: order))
                    heads.append(heads[cur])
                    cur = g.branches.count - 1
                case "checkout", "switch":
                    if let b = findBranch(parseName(rest).0) {
                        cur = b
                    }
                case "merge":
                    let (bName, tail) = parseName(rest)
                    guard let b = findBranch(bName), b != cur, let theirs = heads[b] else { continue }
                    let ours = heads[cur]
                    if let o = ours, reaches(g.commits, from: o, to: theirs) { continue }
                    let a = parseAttrs(tail)
                    let parents = (ours.map { [$0] } ?? []) + [theirs]
                    g.commits.append(GitCommit(id: getAttr(a, "id"), tag: getAttr(a, "tag"), kind: parseKind(a) ?? .merge, branch: cur, parents: parents, picked: nil))
                    heads[cur] = g.commits.count - 1
                case "cherry-pick":
                    let a = parseAttrs(rest)
                    guard let id = getAttr(a, "id"),
                          let src = g.commits.firstIndex(where: { $0.id == id }),
                          g.commits[src].branch != cur else { continue }
                    let parents = heads[cur].map { [$0] } ?? []
                    g.commits.append(GitCommit(id: nil, tag: getAttr(a, "tag"), kind: .cherryPick, branch: cur, parents: parents, picked: src))
                    heads[cur] = g.commits.count - 1
                default:
                    break
                }
            }
        }
        return g.commits.isEmpty ? nil : g
    }

    private static func reaches(_ commits: [GitCommit], from: Int, to: Int) -> Bool {
        var seen = Array(repeating: false, count: commits.count)
        var stack = [from]
        while let c = stack.popLast() {
            if c == to { return true }
            if !seen[c] {
                seen[c] = true
                stack.append(contentsOf: commits[c].parents)
            }
        }
        return false
    }

    private static func parseName(_ s: String) -> (String, String) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") {
            let after = trimmed.dropFirst()
            if let end = after.firstIndex(of: "\"") {
                return (clean(String(after[..<end])), String(after[after.index(after: end)...]))
            }
        }
        if let ws = trimmed.firstIndex(where: \.isWhitespace) {
            return (clean(String(trimmed[..<ws])), String(trimmed[ws...]))
        }
        return (clean(trimmed), "")
    }

    private static func parseAttrs(_ s: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var rest = s.trimmingCharacters(in: .whitespaces)
        while let colon = rest.firstIndex(of: ":") {
            let before = rest[..<colon].trimmingCharacters(in: .whitespaces)
            let key: String
            if let ws = before.lastIndex(where: \.isWhitespace) {
                key = String(before[before.index(after: ws)...])
            } else {
                key = before
            }
            let after = rest[rest.index(after: colon)...].drop(while: \.isWhitespace)
            let value: String
            let next: String
            if after.hasPrefix("\"") {
                let tail = after.dropFirst()
                if let end = tail.firstIndex(of: "\"") {
                    value = String(tail[..<end])
                    next = String(tail[tail.index(after: end)...])
                } else {
                    value = String(tail)
                    next = ""
                }
            } else if let ws = after.firstIndex(where: \.isWhitespace) {
                value = String(after[..<ws])
                next = String(after[ws...])
            } else {
                value = String(after)
                next = ""
            }
            out.append((key, clean(value)))
            rest = next.trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private static func getAttr(_ a: [(String, String)], _ key: String) -> String? {
        a.first(where: { $0.0 == key }).map(\.1).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func parseKind(_ a: [(String, String)]) -> GitCommit.Kind? {
        switch getAttr(a, "type") {
        case "REVERSE": return .reverse
        case "HIGHLIGHT": return .highlight
        case "NORMAL": return .normal
        default: return nil
        }
    }

    static func draw(_ g: GitGraphDiagram, paint: MermaidTheme) -> MermaidScene? {
        let note = MermaidChart.small(paint)
        let head = MermaidChart.bold(note)

        var lanes = Array(g.branches.indices)
        lanes.sort { a, b in
            let ka = g.branches[a].order ?? (a == 0 ? -Float.greatestFiniteMagnitude : Float(a))
            let kb = g.branches[b].order ?? (b == 0 ? -Float.greatestFiniteMagnitude : Float(b))
            return ka != kb ? ka < kb : a < b
        }
        var laneOf = Array(repeating: 0, count: g.branches.count)
        for (pos, b) in lanes.enumerated() {
            laneOf[b] = pos
        }

        let labels = g.commits.map { $0.id.map { measureText($0, font: note) } ?? Measured.empty }
        let tags = g.commits.map { $0.tag.map { measureText($0, font: note) } ?? Measured.empty }
        let names = g.branches.map { measureText($0.name, font: head) }
        func boxed(_ m: Measured) -> Float { m.text.isEmpty ? 0.0 : m.size.x + 2.0 * padX }
        let lh = note.lineHeight ?? (note.size * 1.38)
        let lineH = lh + 2.0 * padY
        let across = g.flow == .right

        var along = Array(repeating: Float(0.0), count: g.commits.count)
        var lastOn: [Int?] = Array(repeating: nil, count: g.branches.count)
        for (k, commit) in g.commits.enumerated() {
            var u: Float = k == 0 ? 0.0 : (along[k - 1] + step)
            if across, let p = lastOn[commit.branch] {
                func w(_ i: Int) -> Float { max(boxed(labels[i]), boxed(tags[i])) }
                u = max(u, along[p] + (w(p) + w(k)) * 0.5 + 10.0)
            }
            along[k] = u
            lastOn[commit.branch] = k
        }

        let hasTags = tags.contains { !$0.text.isEmpty }
        var laneV = Array(repeating: Float(0.0), count: lanes.count)
        if across {
            var v: Float = 0.0
            for (pos, b) in lanes.enumerated() {
                let tagged = zip(g.commits, tags).contains { $0.branch == b && !$1.text.isEmpty }
                if tagged { v += lineH + 10.0 }
                laneV[pos] = v
                v += 2.0 * radius + 22.0 + lineH
            }
        } else {
            let wide: ([Measured]) -> Float = { ms in ms.map(boxed).max() ?? 0.0 }
            let tagW = wide(tags)
            let nameW = names.map { $0.size.x + 24.0 }.max() ?? 0.0
            let lane = max(2.0 * radius + 28.0 + wide(labels) + tagW + (hasTags ? 10.0 : 0.0), nameW)
            for pos in laneV.indices {
                laneV[pos] = tagW + Float(pos) * lane
            }
        }

        func pt(_ u: Float, _ v: Int) -> Vec2 {
            let vv = laneV[v]
            switch g.flow {
            case .right: return Vec2(u, vv)
            case .down: return Vec2(vv, u)
            case .up: return Vec2(vv, -u)
            }
        }

        let end = (along.last ?? 0.0) + 2.0 * radius
        func branchColor(_ b: Int) -> Color { MermaidChart.solid(paint, hue: MermaidChart.hue(b)) }

        var c = Canvas()
        for (b, m) in names.enumerated() {
            let v = laneOf[b]
            let w = m.size.x + 16.0
            let h = m.size.y + 8.0
            let start = pt(-2.0 * radius, v)
            let p0 = pt(0.0, v)
            let at: Vec2
            switch g.flow {
            case .right: at = Vec2(p0.x - 2.0 * radius - 10.0 - w, p0.y - h * 0.5)
            case .down: at = Vec2(p0.x - w * 0.5, -2.0 * radius - 10.0 - h)
            case .up: at = Vec2(p0.x - w * 0.5, 2.0 * radius + 10.0)
            }
            c.dashed([start, pt(end, v)], width: 1.0, color: branchColor(b).alpha(0.45), on: 5.0, off: 4.0)
            c.fill(CanvasMath.roundedRect(x0: at.x, y0: at.y, x1: at.x + w, y1: at.y + h, r: h * 0.5), color: branchColor(b))
            c.labelAt(m, at: Vec2(at.x + 8.0, at.y + 4.0), font: head, color: MermaidChart.ink(branchColor(b)), align: .leading)
        }

        for (k, commit) in g.commits.enumerated() {
            for p in commit.parents {
                let parent = g.commits[p]
                let vp = laneOf[parent.branch]
                let vk = laneOf[commit.branch]
                let a = pt(along[p], vp)
                let b = pt(along[k], vk)
                let pts: [Vec2]
                if vp == vk {
                    pts = [a, b]
                } else if vp < vk {
                    pts = elbow(a, pt(along[p], vk), b)
                } else {
                    pts = elbow(a, pt(along[k], vp), b)
                }
                let laneColor = branchColor(vp < vk ? commit.branch : parent.branch)
                c.stroke(pts, closed: false, width: 2.0, color: laneColor)
            }
            if let src = commit.picked {
                let sv = laneOf[g.commits[src].branch]
                let kv = laneOf[commit.branch]
                let a = pt(along[src], sv)
                let b = pt(along[k], kv)
                c.dashed(elbow(a, pt(along[k], sv), b), width: 1.5, color: branchColor(commit.branch), on: 4.0, off: 3.0)
            }
        }

        for (k, commit) in g.commits.enumerated() {
            let at = pt(along[k], laneOf[commit.branch])
            drawGlyph(&c, kind: commit.kind, at: at, fill: branchColor(commit.branch), paint: paint)
            let label = labels[k]
            if !label.text.isEmpty {
                let w = boxed(label)
                let o = across ? Vec2(at.x - w * 0.5, at.y + radius + 6.0) : Vec2(at.x + radius + 8.0, at.y - lineH * 0.5)
                c.fill(CanvasMath.roundedRect(x0: o.x, y0: o.y, x1: o.x + w, y1: o.y + lineH, r: 4.0), color: oklabMix(paint.surface, paint.text, 0.08))
                c.labelAt(label, at: Vec2(o.x + padX, o.y + padY), font: note, color: paint.muted, align: .leading)
            }
            let tag = tags[k]
            if !tag.text.isEmpty {
                let w = boxed(tag)
                let o = across ? Vec2(at.x - w * 0.5, at.y - radius - 8.0 - lineH) : Vec2(at.x - radius - 8.0 - w, at.y - lineH * 0.5)
                c.shape(CanvasMath.roundedRect(x0: o.x, y0: o.y, x1: o.x + w, y1: o.y + lineH, r: 3.0), fill: paint.noteFill, border: paint.noteBorder, width: 1.0)
                c.labelAt(tag, at: Vec2(o.x + padX, o.y + padY), font: note, color: paint.text, align: .leading)
            }
        }
        return c.finishFitMutating(paint: paint)
    }

    private static func elbow(_ a: Vec2, _ k: Vec2, _ b: Vec2) -> [Vec2] {
        let r = min(10.0, min(CanvasMath.dist(a, k) * 0.5, CanvasMath.dist(k, b) * 0.5))
        if r < 0.5 { return [a, b] }
        let ua = CanvasMath.unit(k, a)
        let ub = CanvasMath.unit(k, b)
        let p = Vec2(k.x + ua.x * r, k.y + ua.y * r)
        let q = Vec2(k.x + ub.x * r, k.y + ub.y * r)
        var pts = [a]
        for i in 0...6 {
            let t = Float(i) / 6.0
            pts.append(CanvasMath.lerp(CanvasMath.lerp(p, k, t), CanvasMath.lerp(k, q, t), t))
        }
        pts.append(b)
        return pts
    }

    private static func drawGlyph(_ c: inout Canvas, kind: GitCommit.Kind, at: Vec2, fill: Color, paint: MermaidTheme) {
        let x = at.x, y = at.y
        if kind == .highlight {
            c.shape(CanvasMath.roundedRect(x0: x - radius, y0: y - radius, x1: x + radius, y1: y + radius, r: 3.0), fill: fill, border: paint.surface, width: 2.0)
            c.fill(CanvasMath.roundedRect(x0: x - radius * 0.5, y0: y - radius * 0.5, x1: x + radius * 0.5, y1: y + radius * 0.5, r: 1.5), color: MermaidChart.ink(fill).alpha(0.4))
        } else {
            c.shape(CanvasMath.ellipse(center: at, rx: radius, ry: radius), fill: fill, border: paint.surface, width: 2.0)
        }
        let mark = MermaidChart.ink(fill)
        switch kind {
        case .merge:
            c.fill(CanvasMath.ellipse(center: at, rx: radius * 0.45, ry: radius * 0.45), color: paint.surface)
        case .reverse:
            let d = radius * 0.45
            c.stroke([Vec2(x - d, y - d), Vec2(x + d, y + d)], closed: false, width: 1.75, color: mark)
            c.stroke([Vec2(x - d, y + d), Vec2(x + d, y - d)], closed: false, width: 1.75, color: mark)
        case .cherryPick:
            c.fill(CanvasMath.ellipse(center: Vec2(x - 2.6, y + 2.0), rx: 2.3, ry: 2.3), color: mark)
            c.fill(CanvasMath.ellipse(center: Vec2(x + 2.6, y + 2.0), rx: 2.3, ry: 2.3), color: mark)
            c.stroke([Vec2(x - 2.0, y), Vec2(x + 0.5, y - 5.0), Vec2(x + 2.4, y)], closed: false, width: 1.0, color: mark)
        case .normal, .highlight:
            break
        }
    }
}
