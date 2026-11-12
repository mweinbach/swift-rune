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
    let from: Int
    let to: Int
    let label: String
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
    private var inNoteBlock = false
    private var pendingNote: (stateId: String, side: StateNote.Side, lines: [String])?

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
        diagram.nodes.count + diagram.edges.count + diagram.clusters.count >= MermaidLimits.maxItems
    }

    private func currentCluster() -> Int? {
        guard let top = scopeStack.last else { return nil }
        return top.regionClusterIndex ?? top.clusterIndex
    }

    private mutating func ensureNode(id: String, kind: StateKind = .normal, label: String? = nil) -> Int {
        if let idx = idMap[id] {
            if kind != .normal && diagram.nodes[idx].kind == .normal {
                diagram.nodes[idx].kind = kind
            }
            if let label, !label.isEmpty, diagram.nodes[idx].label == diagram.nodes[idx].id {
                diagram.nodes[idx].label = label
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
                    diagram.notes.append(StateNote(
                        stateId: pending.stateId,
                        side: pending.side,
                        text: pending.lines.joined(separator: "\n")
                    ))
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
            if let parsed = DiagramDirection.parse(d) {
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

            guard let lhsId = styleSheet.stripInline(lhs),
                  let rhsId = styleSheet.stripInline(rhs) else { return false }

            let fromIdx = lhsId == "[*]" ? addTerminalNode(kind: .start) : ensureNode(id: lhsId)
            let toIdx = rhsId == "[*]" ? addTerminalNode(kind: .end) : ensureNode(id: rhsId)

            diagram.edges.append(StateEdge(from: fromIdx, to: toIdx, label: clean(label)))
            return true
        }

        if let colon = s.firstIndex(of: ":") {
            let idPart = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
            let desc = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !idPart.isEmpty && !idPart.contains(" ") {
                guard let id = styleSheet.stripInline(idPart) else { return false }
                let idx = ensureNode(id: id)
                if !desc.isEmpty {
                    diagram.nodes[idx].descriptions.append(clean(desc))
                }
                return true
            }
        }

        return false
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
            let text = String(afterSide[afterSide.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            diagram.notes.append(StateNote(stateId: stateId, side: side, text: clean(text)))
            return true
        } else {
            pendingNote = (stateId: afterSide, side: side, lines: [])
            inNoteBlock = true
            return true
        }
    }

    private mutating func parseStateDecl(_ body: String) -> Bool {
        var s = body.trimmingCharacters(in: .whitespaces)

        if s.hasSuffix("{") {
            guard scopeStack.count < MermaidLimits.maxDepth else { return false }
            s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
            let (id, label) = parseIdAndAlias(s)
            let clusterIdx = diagram.clusters.count
            diagram.clusters.append(StateCluster(
                id: id,
                label: clean(label),
                parent: currentCluster()
            ))
            scopeStack.append(ScopeFrame(clusterIndex: clusterIdx, regionClusterIndex: nil, regionCount: 0))
            return true
        }

        if let openStereo = s.range(of: "<<"), let closeStereo = s.range(of: ">>", range: openStereo.upperBound..<s.endIndex) {
            let stereo = String(s[openStereo.upperBound..<closeStereo.lowerBound]).trimmingCharacters(in: .whitespaces).lowercased()
            let id = String(s[..<openStereo.lowerBound]).trimmingCharacters(in: .whitespaces)
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

        let (id, label) = parseIdAndAlias(s)
        if !id.isEmpty {
            _ = ensureNode(id: id, kind: .normal, label: clean(label))
            return true
        }
        return false
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
        for i in parser.diagram.nodes.indices {
            parser.diagram.nodes[i].style = parser.styleSheet.get(parser.diagram.nodes[i].id)
        }
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
                    style: .default
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
                line: .solid,
                start: .none,
                end: .arrow,
                minlen: 1,
                style: .default,
                onCluster: (nil, nil)
            )
        }

        let spacing = LayeredLayout.Spacing(node: 28.0, rank: 42.0, cluster: 16.0)
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
