import Foundation
import Rune

// MARK: - State Diagram AST & Parser

enum StateKind: Equatable, Sendable {
    case normal
    case start
    case end
    case choice
    case fork
    case join
    case note
}

struct StateNode: Equatable {
    let id: String
    var label: String
    var kind: StateKind
    var cluster: Int?
    var descriptions: [String] = []
    var style: NodeStyle = .default
}

struct StateEdge: Equatable {
    var from: Int
    var to: Int
    let label: String
    var line: EdgeLine = .solid
    var end: EdgeHead = .arrow
}

struct StateCluster: Equatable {
    let id: String
    let label: String
    let parent: Int?
    var isRegion: Bool = false
    var regionIndex: Int = 0
}

struct StateNote: Equatable {
    enum Side: Equatable {
        case left
        case right
    }
    let stateId: String
    let side: Side
    let text: String
}

struct StateDiagram {
    var title: String?
    var dir: DiagramDirection = .down
    var nodes: [StateNode] = []
    var edges: [StateEdge] = []
    var clusters: [StateCluster] = []
    var notes: [StateNote] = []
}

struct StateParser: LenientParser {
    struct Mark {
        let nodeCount: Int
        let edgeCount: Int
        let clusterCount: Int
        let noteCount: Int
        let dir: DiagramDirection
        let scopeStack: [ScopeFrame]
        let idMap: [String: Int]
    }

    struct ScopeFrame: Equatable {
        let clusterIndex: Int
        var regionClusterIndex: Int?
        var regionCount: Int
    }

    var diagram = StateDiagram()
    var styleSheet = StyleSheet()
    private var scopeStack: [ScopeFrame] = []
    private var idMap: [String: Int] = [:]
    private var compositeIds: [String: Int] = [:]
    private var inNoteBlock = false
    private var pendingNote: (stateId: String, side: StateNote.Side, lines: [String])?
    private var overLimit = false

    func mark() -> Mark {
        Mark(
            nodeCount: diagram.nodes.count,
            edgeCount: diagram.edges.count,
            clusterCount: diagram.clusters.count,
            noteCount: diagram.notes.count,
            dir: diagram.dir,
            scopeStack: scopeStack,
            idMap: idMap
        )
    }

    mutating func undo(_ mark: Mark) {
        if diagram.nodes.count > mark.nodeCount {
            diagram.nodes.removeSubrange(mark.nodeCount...)
        }
        if diagram.edges.count > mark.edgeCount {
            diagram.edges.removeSubrange(mark.edgeCount...)
        }
        if diagram.clusters.count > mark.clusterCount {
            diagram.clusters.removeSubrange(mark.clusterCount...)
        }
        if diagram.notes.count > mark.noteCount {
            diagram.notes.removeSubrange(mark.noteCount...)
        }
        diagram.dir = mark.dir
        scopeStack = mark.scopeStack
        idMap = mark.idMap
    }

    func isOverLimit() -> Bool {
        overLimit || (diagram.nodes.count + diagram.edges.count + diagram.clusters.count >= MermaidLimits.maxItems)
    }

    private mutating func budget() -> Bool {
        if diagram.nodes.count + diagram.edges.count + diagram.clusters.count >= MermaidLimits.maxItems {
            overLimit = true
            return false
        }
        return true
    }

    private func currentCluster() -> Int? {
        guard let top = scopeStack.last else { return nil }
        return top.regionClusterIndex ?? top.clusterIndex
    }

    private static func validStateId(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    private mutating func ensureNode(id: String, kind: StateKind = .normal, label: String? = nil) -> Int {
        if let idx = idMap[id] {
            if kind != .normal && diagram.nodes[idx].kind == .normal {
                diagram.nodes[idx].kind = kind
            }
            if let label, !label.isEmpty, diagram.nodes[idx].label == diagram.nodes[idx].id {
                diagram.nodes[idx].label = label
            }
            if diagram.nodes[idx].cluster == nil {
                diagram.nodes[idx].cluster = currentCluster()
            }
            return idx
        }
        let idx = diagram.nodes.count
        let node = StateNode(
            id: id,
            label: label ?? id,
            kind: kind,
            cluster: currentCluster()
        )
        diagram.nodes.append(node)
        idMap[id] = idx
        return idx
    }

    private mutating func addTerminalNode(kind: StateKind) -> Int {
        let idx = diagram.nodes.count
        let node = StateNode(
            id: kind == .start ? "[*]__start_\(idx)" : "[*]__end_\(idx)",
            label: "",
            kind: kind,
            cluster: currentCluster()
        )
        diagram.nodes.append(node)
        return idx
    }

    mutating func readStatement(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.hasPrefix("%%") {
            return true
        }

        if inNoteBlock {
            if s.lowercased() == "end note" {
                if let pending = pendingNote {
                    _ = addNote(target: pending.stateId, side: pending.side, text: pending.lines.joined(separator: "\n"))
                }
                pendingNote = nil
                inNoteBlock = false
                return true
            }
            pendingNote?.lines.append(s)
            return true
        }

        let lower = s.lowercased()

        if s == "}" {
            if !scopeStack.isEmpty {
                scopeStack.removeLast()
            }
            return true
        }

        if s == "--" {
            if var top = scopeStack.popLast() {
                if top.regionClusterIndex == nil {
                    let firstRegionIdx = diagram.clusters.count
                    diagram.clusters.append(StateCluster(
                        id: "\(diagram.clusters[top.clusterIndex].id)__r0",
                        label: "",
                        parent: top.clusterIndex,
                        isRegion: true,
                        regionIndex: 0
                    ))
                    for i in diagram.nodes.indices where diagram.nodes[i].cluster == top.clusterIndex {
                        diagram.nodes[i].cluster = firstRegionIdx
                    }
                    for i in 0..<firstRegionIdx where diagram.clusters[i].parent == top.clusterIndex {
                        diagram.clusters[i] = StateCluster(
                            id: diagram.clusters[i].id,
                            label: diagram.clusters[i].label,
                            parent: firstRegionIdx,
                            isRegion: diagram.clusters[i].isRegion,
                            regionIndex: diagram.clusters[i].regionIndex
                        )
                    }
                    top.regionCount = 1
                }
                let nextRegionIdx = diagram.clusters.count
                let regNum = top.regionCount
                diagram.clusters.append(StateCluster(
                    id: "\(diagram.clusters[top.clusterIndex].id)__r\(regNum)",
                    label: "",
                    parent: top.clusterIndex,
                    isRegion: true,
                    regionIndex: regNum
                ))
                top.regionClusterIndex = nextRegionIdx
                top.regionCount += 1
                scopeStack.append(top)
            }
            return true
        }

        if lower.hasPrefix("title ") {
            let t = cleanQuoted(String(s.dropFirst(6)))
            if !t.isEmpty { diagram.title = t }
            return true
        }

        if lower.hasPrefix("direction ") {
            let d = String(s.dropFirst("direction ".count)).trimmingCharacters(in: .whitespaces).uppercased()
            guard let parsed = DiagramDirection.parse(d) else { return false }
            if scopeStack.isEmpty && diagram.edges.isEmpty {
                diagram.dir = parsed
            }
            return true
        }

        if lower.hasPrefix("classdef ") {
            return styleSheet.classDef(String(s.dropFirst("classDef ".count)))
        }
        if lower.hasPrefix("class ") {
            return styleSheet.assignClasses(String(s.dropFirst("class ".count)))
        }
        if lower.hasPrefix("style ") {
            return styleSheet.style(String(s.dropFirst("style ".count)))
        }
        if lower.hasPrefix("acctitle") || lower.hasPrefix("accdescr") {
            return true
        }

        if lower.hasPrefix("note ") {
            return parseNote(s)
        }

        if lower.hasPrefix("state ") {
            return parseStateDecl(String(s.dropFirst("state ".count)))
        }

        if let arrowRange = s.range(of: "-->") {
            let lhs = String(s[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhsAndLabel = String(s[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let (rhs, label) = splitColonLabel(rhsAndLabel)
            if lhs.isEmpty || rhs.isEmpty { return false }

            guard let from = endpoint(lhs, isStart: true),
                  let to = endpoint(rhs, isStart: false),
                  !from.isEmpty, !to.isEmpty,
                  budget() else { return false }

            diagram.edges.append(StateEdge(
                from: from[0],
                to: to[0],
                label: cleanQuoted(label),
                line: .solid,
                end: .arrow
            ))
            holdRegions(from: from, to: to)
            return true
        }

        if let colon = s.firstIndex(of: ":") {
            let idPart = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
            let desc = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard let id = styleSheet.stripInline(idPart), Self.validStateId(id), budget() else {
                return false
            }
            let idx = ensureNode(id: id)
            let cleaned = cleanQuoted(desc)
            if !cleaned.isEmpty {
                diagram.nodes[idx].descriptions.append(cleaned)
            }
            return true
        }

        if Self.validStateId(s) && budget() {
            _ = ensureNode(id: s)
            return true
        }

        return false
    }

    private mutating func addNote(target: String, side: StateNote.Side, text: String) -> Bool {
        guard budget() else { return false }
        let at = ensureNode(id: target)
        guard budget() else { return false }
        diagram.notes.append(StateNote(stateId: target, side: side, text: text))
        let cluster = diagram.nodes[at].cluster
        let noteId = "__note_\(diagram.nodes.count)"
        diagram.nodes.append(StateNode(id: noteId, label: text, kind: .note, cluster: cluster))
        let noteIdx = diagram.nodes.count - 1
        let (from, to) = side == .left ? (noteIdx, at) : (at, noteIdx)
        guard budget() else { return false }
        diagram.edges.append(StateEdge(from: from, to: to, label: "", line: .dotted, end: .none))
        return true
    }

    private mutating func parseNote(_ s: String) -> Bool {
        let rest = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        let lower = rest.lowercased()
        let side: StateNote.Side
        var afterSide: String
        if lower.hasPrefix("left of ") {
            side = .left
            afterSide = String(rest.dropFirst("left of ".count))
        } else if lower.hasPrefix("right of ") {
            side = .right
            afterSide = String(rest.dropFirst("right of ".count))
        } else {
            return false
        }
        afterSide = afterSide.trimmingCharacters(in: .whitespaces)
        if let colon = afterSide.firstIndex(of: ":") {
            let stateId = String(afterSide[..<colon]).trimmingCharacters(in: .whitespaces)
            guard Self.validStateId(stateId) else { return false }
            let text = String(afterSide[afterSide.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return addNote(target: stateId, side: side, text: cleanQuoted(text))
        } else {
            guard Self.validStateId(afterSide) else { return false }
            pendingNote = (stateId: afterSide, side: side, lines: [])
            inNoteBlock = true
            return true
        }
    }

    private mutating func parseStateDecl(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        let opens = trimmed.hasSuffix("{")
        let s = opens
            ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
            : trimmed

        if let openStereo = s.range(of: "<<") {
            let afterOpen = String(s[openStereo.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard afterOpen.hasSuffix(">>") else { return false }
            let stereo = String(afterOpen.dropLast(2)).trimmingCharacters(in: .whitespaces).lowercased()
            let id = String(s[..<openStereo.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard Self.validStateId(id), budget() else { return false }
            let kind: StateKind
            switch stereo {
            case "choice": kind = .choice
            case "fork": kind = .fork
            case "join": kind = .join
            default: kind = .normal
            }
            _ = ensureNode(id: id, kind: kind)
            return true
        }

        if opens {
            if !budget() { return false }
            if scopeStack.count >= MermaidLimits.maxDepth {
                overLimit = true
                return false
            }
            let (id, label) = parseIdAndAlias(s)
            let validId = Self.validStateId(id)
            let clusterIdx = diagram.clusters.count
            let title = validId ? clean(label) : cleanQuoted(s)
            diagram.clusters.append(StateCluster(
                id: validId ? id : "__composite_\(clusterIdx)",
                label: title,
                parent: currentCluster()
            ))
            if validId {
                compositeIds[id] = clusterIdx
            }
            scopeStack.append(ScopeFrame(clusterIndex: clusterIdx, regionClusterIndex: nil, regionCount: 0))
            return true
        }

        let (id, label) = parseIdAndAlias(s)
        guard Self.validStateId(id), budget() else { return false }
        let idx = ensureNode(id: id, kind: .normal, label: clean(label))
        diagram.nodes[idx].label = clean(label)
        return true
    }

    private func within(cluster start: Int?, cid: Int) -> Bool {
        var cur = start
        for _ in 0...MermaidLimits.maxDepth {
            guard let c = cur else { return false }
            if c == cid { return true }
            cur = diagram.clusters[c].parent
        }
        return false
    }

    private func compositeEnds(_ cid: Int, leaving: Bool) -> [Int] {
        let regions = (0..<diagram.clusters.count).filter {
            diagram.clusters[$0].isRegion && diagram.clusters[$0].parent == cid
        }
        let scopes = regions.isEmpty ? [cid] : regions
        return scopes.compactMap { scope in
            let members = (0..<diagram.nodes.count).filter { i in
                diagram.nodes[i].kind != .note && within(cluster: diagram.nodes[i].cluster, cid: scope)
            }
            if leaving {
                return members.last { diagram.nodes[$0].kind != .start }
            } else {
                return members.first
            }
        }
    }

    private mutating func endpoint(_ raw: String, isStart: Bool) -> [Int]? {
        if raw == "[*]" {
            guard budget() else { return nil }
            return [addTerminalNode(kind: isStart ? .start : .end)]
        }
        guard let id = styleSheet.stripInline(raw), Self.validStateId(id) else {
            return nil
        }
        if let cid = compositeIds[id] {
            let ends = compositeEnds(cid, leaving: isStart)
            if !ends.isEmpty {
                return ends
            }
        }
        guard budget() else { return nil }
        return [ensureNode(id: id)]
    }

    private mutating func holdRegions(from: [Int], to: [Int]) {
        guard let fromMax = from.max(), let toMin = to.min(), fromMax < toMin else {
            return
        }
        var pairs: [(Int, Int)] = []
        for f in from.dropFirst() { pairs.append((f, to[0])) }
        for t in to.dropFirst() { pairs.append((from[0], t)) }
        for (f, t) in pairs {
            guard budget() else { return }
            diagram.edges.append(StateEdge(from: f, to: t, label: "", line: .invisible, end: .none))
        }
    }

    private mutating func resolveComposites() {
        var moves: [Int: (enter: [Int], leave: [Int])] = [:]
        for (id, cid) in compositeIds {
            guard let at = idMap[id] else { continue }
            if within(cluster: diagram.nodes[at].cluster, cid: cid) {
                continue
            }
            let enter = compositeEnds(cid, leaving: false)
            let leave = compositeEnds(cid, leaving: true)
            if !enter.isEmpty && !leave.isEmpty {
                moves[at] = (enter, leave)
            }
        }
        guard !moves.isEmpty else { return }
        let originalEdgeCount = diagram.edges.count
        for e in 0..<originalEdgeCount {
            let origFrom = diagram.edges[e].from
            let origTo = diagram.edges[e].to
            let fromList = moves[origFrom]?.leave ?? [origFrom]
            let toList = moves[origTo]?.enter ?? [origTo]
            diagram.edges[e].from = fromList[0]
            diagram.edges[e].to = toList[0]
            holdRegions(from: fromList, to: toList)
        }
        var remap = Array(repeating: 0, count: diagram.nodes.count)
        var kept = 0
        for i in diagram.nodes.indices {
            remap[i] = kept
            if moves[i] == nil {
                kept += 1
            }
        }
        for e in diagram.edges.indices {
            diagram.edges[e].from = remap[diagram.edges[e].from]
            diagram.edges[e].to = remap[diagram.edges[e].to]
        }
        diagram.nodes = diagram.nodes.enumerated().compactMap { moves[$0.offset] == nil ? $0.element : nil }
        idMap.removeAll()
    }

    private func parseIdAndAlias(_ s: String) -> (id: String, label: String) {
        if s.hasPrefix("\"") {
            if let endQuote = s.dropFirst().firstIndex(of: "\"") {
                let label = String(s[s.index(after: s.startIndex)..<endQuote])
                let after = String(s[s.index(after: endQuote)...]).trimmingCharacters(in: .whitespaces)
                if after.lowercased().hasPrefix("as ") {
                    let id = String(after.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    return (id, label)
                }
                return (label, label)
            }
        }
        if let asRange = s.range(of: " as ", options: .caseInsensitive) {
            let label = String(s[..<asRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let id = String(s[asRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (id, cleanQuoted(label))
        }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return (trimmed, trimmed)
    }

    private func splitColonLabel(_ s: String) -> (String, String) {
        if let colon = s.firstIndex(of: ":") {
            let rhs = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
            let label = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return (rhs, label)
        }
        return (s, "")
    }

    static func parse(_ header: String, _ body: [String]) -> StateDiagram? {
        var parser = StateParser()
        var reader = LenientReader()
        for line in body {
            for stmt in statements(line) {
                if !reader.read(&parser, statement: stmt) {
                    return nil
                }
            }
        }
        if parser.inNoteBlock, let pending = parser.pendingNote {
            parser.inNoteBlock = false
            parser.pendingNote = nil
            if !parser.addNote(target: pending.stateId, side: pending.side, text: pending.lines.joined(separator: "\n")) && parser.isOverLimit() {
                return nil
            }
        }
        for i in parser.diagram.nodes.indices {
            parser.diagram.nodes[i].style = parser.styleSheet.get(parser.diagram.nodes[i].id)
        }
        parser.resolveComposites()
        guard !parser.diagram.nodes.isEmpty else { return nil }
        return parser.diagram
    }
}

// MARK: - State Diagram Drawer

enum StateDrawer {
    static func draw(
        _ diagram: StateDiagram,
        paint: MermaidTheme,
        hover: (MermaidHover, Color)? = nil
    ) -> MermaidScene? {
        guard !diagram.nodes.isEmpty else { return nil }

        let clusters = diagram.clusters.map { c in
            ClusterSpec(title: c.label, parent: c.parent)
        }

        var drawNodes: [DrawNode] = []
        drawNodes.reserveCapacity(diagram.nodes.count)

        for node in diagram.nodes {
            switch node.kind {
            case .start:
                drawNodes.append(.start(cluster: node.cluster))
            case .end:
                drawNodes.append(.end(cluster: node.cluster))
            case .fork, .join:
                drawNodes.append(.bar(cluster: node.cluster))
            case .choice:
                drawNodes.append(.shape(
                    shape: .diamond,
                    label: .empty,
                    size: Vec2(28, 28),
                    cluster: node.cluster,
                    style: node.style
                ))
            case .note:
                let measured = measureBalanced(node.label, font: paint.font)
                let size = ShapeRenderer.nodeSize(.note, labelSize: measured.size)
                drawNodes.append(.shape(
                    shape: .note,
                    label: measured,
                    size: size,
                    cluster: node.cluster,
                    style: node.style
                ))
            case .normal:
                var labelText = node.label
                if !node.descriptions.isEmpty {
                    labelText += "\n" + node.descriptions.joined(separator: "\n")
                }
                let measured = measureBalanced(labelText, font: paint.font)
                let size = ShapeRenderer.nodeSize(.round, labelSize: measured.size)
                drawNodes.append(.shape(
                    shape: .round,
                    label: measured,
                    size: size,
                    cluster: node.cluster,
                    style: node.style
                ))
            }
        }

        let drawEdges = diagram.edges.map { e in
            LayeredEdge(
                from: e.from,
                to: e.to,
                label: e.label.isEmpty ? nil : e.label,
                line: e.line,
                start: .none,
                end: e.end,
                minlen: 1,
                style: .default,
                onCluster: (nil, nil)
            )
        }

        let spacing = LayeredLayout.Spacing(node: 34.0, rank: 42.0, cluster: 14.0)
        let nodeIds = diagram.nodes.map(\.id)
        guard var canvas = LayeredDrawer.layeredCanvas(
            dir: diagram.dir,
            nodes: drawNodes,
            ids: nodeIds,
            edges: drawEdges,
            clusters: clusters,
            spacing: spacing,
            paint: paint,
            hover: hover
        ) else { return nil }
        canvas.names = PartNames.fromLayered(
            nodes: nodeIds,
            edges: drawEdges.map { ($0.from, $0.to) },
            frames: diagram.clusters.map(\.id)
        )
        return canvas.finishFit(paint: paint)
    }
}
