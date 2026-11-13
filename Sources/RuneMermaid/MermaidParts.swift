import Foundation
import Rune

enum PartKind: Equatable {
    case node
    case edge
    case frame

    var prefix: String {
        switch self {
        case .node: "n:"
        case .edge: "e:"
        case .frame: "g:"
        }
    }

    var enter: Transition {
        switch self {
        case .node: .scale(0.96)
        case .edge: .draw
        case .frame: .opacity
        }
    }

    var labelEnter: (Transition, Float) {
        switch self {
        case .node: (.scale(0.96), 0.0)
        case .edge: (.opacity, 0.12)
        case .frame: (.opacity, 0.0)
        }
    }
}

enum Part: Equatable {
    case index(PartKind, Int)
    case key(PartKind, String)
}

struct PartNames {
    var nodes: [String] = []
    var edges: [String] = []
    var frames: [String] = []

    init(nodes: [String] = [], edges: [String] = [], frames: [String] = []) {
        self.nodes = nodes
        self.edges = edges
        self.frames = frames
    }

    static func fromLayered(nodes: [String], edges: [(from: Int, to: Int)], frames: [String]) -> PartNames {
        struct EdgePair: Hashable {
            let from: Int
            let to: Int
        }
        func nodeId(_ i: Int) -> String {
            i < nodes.count ? nodes[i] : "#\(i)"
        }
        var seen: [EdgePair: Int] = [:]
        var edgeNames: [String] = []
        edgeNames.reserveCapacity(edges.count)
        for e in edges {
            let pair = EdgePair(from: e.from, to: e.to)
            let count = (seen[pair] ?? 0) + 1
            seen[pair] = count
            let base = "\(nodeId(e.from))>\(nodeId(e.to))"
            edgeNames.append(count == 1 ? base : "\(base)~\(count - 1)")
        }
        return PartNames(nodes: nodes, edges: edgeNames, frames: frames)
    }

    func key(for part: Part) -> (String, PartKind) {
        switch part {
        case let .index(kind, i):
            let list: [String] = switch kind {
            case .node: nodes
            case .edge: edges
            case .frame: frames
            }
            let name = i < list.count ? list[i] : "#\(i)"
            return ("\(kind.prefix)\(name)", kind)
        case let .key(kind, s):
            return ("\(kind.prefix)\(s)", kind)
        }
    }
}

struct PartMark {
    let opIndex: Int
    let labelIndex: Int
    let part: Part?
}

struct ScenePiece {
    let key: String
    let kind: PartKind?
    let at: Vec2
    let size: Vec2
    let shapes: [Shape]

    func el<State>(streaming: Bool, scale: Float) -> El<State> {
        let enter: Transition = switch kind {
        case let .some(k) where streaming: k.enter
        case .none where streaming: .opacity
        default: .none
        }
        var node = El<State>(direction: .row)
            .key(key)
            .absolute(x: 0, y: 0)
            .offset(at.x * scale, at.y * scale)
            .size(size.x * scale, size.y * scale)
            .transition(enter)
        node.shapes = shapes
        return node
    }
}

typealias LabelKey = (key: String, kind: PartKind?)

enum PartSplitter {
    static func split(canvas: Canvas, map: (Vec2) -> Vec2) -> ([ScenePiece], [LabelKey]) {
        var pieces: [ScenePiece] = []
        var labelKeys: [LabelKey] = Array(repeating: ("", nil), count: canvas.labels.count)
        var seen: [String: Int] = [:]
        var restLabels = 0
        var restRuns = 0

        for (part, opRange, labelRange) in canvas.runs() {
            let (key, kind): (String, PartKind?)
            if let p = part {
                let resolved = canvas.partKey(p)
                key = resolved.0
                kind = resolved.1
            } else {
                restRuns += 1
                key = restRuns == 1 ? "shape" : "shape\(restRuns)"
                kind = nil
            }
            let n = seen[key] ?? 0
            let runKey = n == 0 ? key : "\(key)~\(n)"
            seen[key] = n + 1

            for (j, i) in labelRange.enumerated() {
                if let k = kind {
                    labelKeys[i] = ("\(runKey).t\(j)", k)
                } else {
                    restLabels += 1
                    labelKeys[i] = ("t\(restLabels - 1)", nil)
                }
            }

            if let piece = makePiece(ops: Array(canvas.ops[opRange]), key: runKey, kind: kind, map: map) {
                pieces.append(piece)
            }
        }
        return (pieces, labelKeys)
    }

    private static func makePiece(ops: [CanvasOp], key: String, kind: PartKind?, map: (Vec2) -> Vec2) -> ScenePiece? {
        var x0 = Float.greatestFiniteMagnitude
        var y0 = Float.greatestFiniteMagnitude
        var x1 = -Float.greatestFiniteMagnitude
        var y1 = -Float.greatestFiniteMagnitude

        func add(_ p: Vec2, _ r: Float) {
            x0 = min(x0, p.x - r)
            y0 = min(y0, p.y - r)
            x1 = max(x1, p.x + r)
            y1 = max(y1, p.y + r)
        }

        for op in ops {
            switch op {
            case let .fill(points, _):
                for p in points { add(map(p), 0) }
            case let .stroke(points, _, width, _, _):
                for p in points { add(map(p), width / 2.0 + 1.0) }
            }
        }

        if x0 > x1 { return nil }
        let origin = Vec2(x0, y0)
        let size = Vec2(max(x1 - x0, 1.0), max(y1 - y0, 1.0))

        let shapes: [Shape] = ops.map { op in
            let localPoints: [Vec2] = switch op {
            case let .fill(pts, _), let .stroke(pts, _, _, _, _):
                pts.map {
                    let mapped = map($0)
                    return Vec2(mapped.x - origin.x, mapped.y - origin.y)
                }
            }
            let shape = op.toShape(points: localPoints)
            return shape.viewBox(size.x, size.y)
        }

        return ScenePiece(key: key, kind: kind, at: origin, size: size, shapes: shapes)
    }
}
