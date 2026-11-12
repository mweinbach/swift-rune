import Foundation
import Rune

// MARK: - Top-Level Mermaid Parsing & Rendering API

enum ParsedDiagram {
    case flowchart(FlowchartDiagram)
    case sequence(SequenceDiagram)
    case state(StateDiagram)
    case classDiagram(ClassDiagram)
    case er(ErDiagram)
    case gantt(GanttDiagram)
    case pie(PieDiagram)
    case mindmap(MindmapDiagram)
    case timeline(TimelineDiagram)
    case journey(JourneyDiagram)
    case git(GitGraphDiagram)
    case quadrant(QuadrantDiagram)
    case xyChart(XYChartDiagram)
    case sankey(SankeyDiagram)
    case block(BlockDiagram)
    case requirement(RequirementDiagram)
    case c4(C4Diagram)

    var title: String? {
        switch self {
        case let .flowchart(d): d.title
        case let .sequence(d): d.title
        case let .state(d): d.title
        case let .classDiagram(d): d.title
        case let .er(d): d.title
        case let .gantt(d): d.title
        case let .pie(d): d.title
        case .mindmap: nil
        case let .timeline(d): d.title
        case let .journey(d): d.title
        case .git: nil
        case let .quadrant(d): d.title
        case let .xyChart(d): d.title
        case .sankey: nil
        case .block: nil
        case .requirement: nil
        case let .c4(d): d.title
        }
    }

    func withFrontTitle(_ frontTitle: String?) -> ParsedDiagram {
        guard let ft = frontTitle, title == nil else { return self }
        switch self {
        case var .flowchart(d): d.title = ft; return .flowchart(d)
        case var .sequence(d): d.title = ft; return .sequence(d)
        case var .state(d): d.title = ft; return .state(d)
        case var .classDiagram(d): d.title = ft; return .classDiagram(d)
        case var .er(d): d.title = ft; return .er(d)
        case var .gantt(d): d.title = ft; return .gantt(d)
        case var .pie(d): d.title = ft; return .pie(d)
        case .mindmap: return self
        case var .timeline(d): d.title = ft; return .timeline(d)
        case var .journey(d): d.title = ft; return .journey(d)
        case .git: return self
        case var .quadrant(d): d.title = ft; return .quadrant(d)
        case var .xyChart(d): d.title = ft; return .xyChart(d)
        case .sankey: return self
        case .block: return self
        case .requirement: return self
        case var .c4(d): d.title = ft; return .c4(d)
        }
    }
}

enum MermaidParser {
    private static let supportedKinds: Set<String> = [
        "graph", "flowchart",
        "sequenceDiagram",
        "stateDiagram", "stateDiagram-v2",
        "classDiagram", "classDiagram-v2",
        "erDiagram",
        "gantt",
        "pie",
        "mindmap",
        "timeline",
        "journey",
        "gitGraph", "gitGraph:",
        "quadrantChart",
        "xychart-beta", "xychart",
        "sankey-beta", "sankey",
        "block-beta", "block",
        "requirementDiagram",
        "C4Context", "C4Container", "C4Component", "C4Dynamic", "C4Deployment",
    ]

    static func splitHeader(_ header: String) -> (String, String) {
        if let idx = header.firstIndex(where: { $0.isWhitespace || $0 == ";" }) {
            let kind = String(header[..<idx])
            let rest = String(header[idx...]).trimmingCharacters(in: .whitespaces)
            return (kind, rest)
        }
        return (header, "")
    }

    static func isSupportedKind(_ kind: String) -> Bool {
        supportedKinds.contains(kind)
    }

    static func parse(_ source: String) -> ParsedDiagram? {
        let (cleaned, frontTitle) = stripFrontMatterAndDirectives(source)
        let rawLines = cleaned
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard let headerIdx = rawLines.firstIndex(where: { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && !t.hasPrefix("%%")
        }) else {
            return nil
        }

        let header = rawLines[headerIdx].trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String] = []
        var indents: [Int] = []
        for raw in rawLines[(headerIdx + 1)...] {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("%%") { continue }
            let indent = raw.prefix(while: { $0.isWhitespace }).count
            body.append(t)
            indents.append(indent)
        }

        let (headWord, headerRest) = splitHeader(header)
        let parsed: ParsedDiagram?
        switch headWord {
        case "flowchart", "graph":
            parsed = FlowchartParser.parse(header: headerRest, body: body).map(ParsedDiagram.flowchart)
        case "sequenceDiagram":
            parsed = SequenceParser.parse(header: headerRest, body: body).map(ParsedDiagram.sequence)
        case "stateDiagram", "stateDiagram-v2":
            parsed = StateParser.parse(headerRest, body).map(ParsedDiagram.state)
        case "classDiagram", "classDiagram-v2":
            parsed = ClassParser.parse(headerRest, body).map(ParsedDiagram.classDiagram)
        case "erDiagram":
            parsed = ErParser.parse(headerRest, body).map(ParsedDiagram.er)
        case "gantt":
            parsed = GanttParser.parse(header: headerRest, body: body).map(ParsedDiagram.gantt)
        case "pie":
            parsed = PieParser.parse(header: headerRest, body: body).map(ParsedDiagram.pie)
        case "mindmap":
            parsed = MindmapParser.parse(body: body, indents: indents).map(ParsedDiagram.mindmap)
        case "timeline":
            parsed = TimelineParser.parse(header: headerRest, body: body).map(ParsedDiagram.timeline)
        case "journey":
            parsed = JourneyParser.parse(body).map(ParsedDiagram.journey)
        case "gitGraph", "gitGraph:":
            parsed = GitParser.parse(header: headerRest, body: body).map(ParsedDiagram.git)
        case "quadrantChart":
            parsed = QuadrantParser.parse(body).map(ParsedDiagram.quadrant)
        case "xychart-beta", "xychart":
            parsed = XYChartParser.parse(header: headerRest, body: body).map(ParsedDiagram.xyChart)
        case "sankey-beta", "sankey":
            parsed = SankeyParser.parse(body).map(ParsedDiagram.sankey)
        case "block-beta", "block":
            parsed = BlockParser.parse(body).map(ParsedDiagram.block)
        case "requirementDiagram":
            parsed = RequirementParser.parse(body).map(ParsedDiagram.requirement)
        case "C4Context", "C4Container", "C4Component", "C4Dynamic", "C4Deployment":
            parsed = C4Parser.parse(header: headWord, body: body).map(ParsedDiagram.c4)
        default:
            parsed = nil
        }
        return parsed?.withFrontTitle(frontTitle)
    }

    static func stripFrontMatterAndDirectives(_ source: String) -> (String, String?) {
        var s = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var frontTitle: String? = nil

        let trimmed = s.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
        if trimmed.hasPrefix("---") {
            let afterOpen = trimmed.dropFirst(3)
            if afterOpen.first == "\n" || afterOpen.first == " " {
                if let closeRange = afterOpen.range(of: "\n---") {
                    let fm = String(afterOpen[..<closeRange.lowerBound])
                    for line in fm.split(separator: "\n") {
                        let t = line.trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix("title:") {
                            let val = cleanQuoted(String(t.dropFirst("title:".count)))
                            if !val.isEmpty { frontTitle = val }
                        }
                    }
                    let afterClose = afterOpen[closeRange.upperBound...]
                    if let nl = afterClose.firstIndex(of: "\n") {
                        s = String(afterClose[afterClose.index(after: nl)...])
                    } else {
                        s = ""
                    }
                }
            }
        }

        while let start = s.range(of: "%%{"),
              let end = s.range(of: "}%%", range: start.upperBound..<s.endIndex) {
            s.removeSubrange(start.lowerBound..<end.upperBound)
        }

        return (s, frontTitle)
    }
}

/// Whether `source` starts with a Mermaid diagram type that `RuneMermaid` renders.
public func supportedMermaid(_ source: String) -> Bool {
    let (cleaned, _) = MermaidParser.stripFrontMatterAndDirectives(source)
    for line in cleaned.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("%%") { continue }
        let (headWord, _) = MermaidParser.splitHeader(t)
        return MermaidParser.isSupportedKind(headWord)
    }
    return false
}

/// Whether `source`, the complete lines of a diagram still arriving, may draw once more arrive.
public func mayDrawMermaid(_ source: String) -> Bool {
    let (cleaned, _) = MermaidParser.stripFrontMatterAndDirectives(source)
    for line in cleaned.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("%%") { continue }
        let (headWord, _) = MermaidParser.splitHeader(t)
        return MermaidParser.isSupportedKind(headWord)
    }
    return true
}

/// Whether `source` parses cleanly as a supported Mermaid diagram.
public func canRenderMermaid(_ source: String) -> Bool {
    MermaidParser.parse(source) != nil
}

/// Render a Mermaid diagram into a card `El<State>`, or `nil` if unsupported/invalid.
public func renderMermaid<State>(
    _ source: String,
    theme: MermaidTheme = .neutral(dark: false),
    hover: (MermaidHover, Color)? = nil
) -> El<State>? {
    guard let scene = MermaidScenes.built(source, theme: theme, hover: hover, prev: nil).scene else {
        return nil
    }
    return scene.el(paint: theme)
}

/// Render a Mermaid diagram while streaming in (`steady` layout holding).
public func renderMermaidStreaming<State>(
    _ source: String,
    theme: MermaidTheme = .neutral(dark: false),
    hover: (MermaidHover, Color)? = nil
) -> El<State>? {
    guard let scene = MermaidScenes.growing(source, theme: theme, hover: hover) else {
        return nil
    }
    return scene.el(paint: theme)
}

/// Render a finished streamed Mermaid diagram settled to its final layout.
public func renderMermaidStreamed<State>(
    _ source: String,
    theme: MermaidTheme = .neutral(dark: false),
    hover: (MermaidHover, Color)? = nil
) -> El<State>? {
    renderMermaid(source, theme: theme, hover: hover)
}

/// Render a Mermaid diagram into a frameless `MermaidDrawing<State>`, or `nil` if unsupported/invalid.
public func renderMermaidDrawing<State>(
    _ source: String,
    theme: MermaidTheme = .neutral(dark: false),
    hover: (MermaidHover, Color)? = nil
) -> MermaidDrawing<State>? {
    guard let scene = MermaidScenes.built(source, theme: theme, hover: hover, prev: nil).scene else {
        return nil
    }
    let (drawingEl, sz): (El<State>, Vec2) = scene.drawing(paint: theme)
    return MermaidDrawing(el: drawingEl, size: sz, surface: theme.surface, surfaceBorder: theme.surfaceBorder)
}

func renderScene(
    _ parsed: ParsedDiagram,
    theme: MermaidTheme,
    hover: (MermaidHover, Color)? = nil
) -> MermaidScene? {
    switch parsed {
    case let .flowchart(d):
        return FlowchartParser.draw(d, paint: theme, hover: hover)
    case let .sequence(d):
        return SequenceDrawer.draw(d, paint: theme)
    case let .state(d):
        return StateDrawer.draw(d, paint: theme, hover: hover)
    case let .classDiagram(d):
        return ClassDrawer.draw(d, paint: theme, hover: hover)
    case let .er(d):
        return ErDrawer.draw(d, paint: theme, hover: hover)
    case let .gantt(d):
        return GanttParser.draw(d, paint: theme)
    case let .pie(d):
        return PieParser.draw(d, paint: theme)
    case let .mindmap(d):
        return MindmapParser.draw(d, paint: theme)
    case let .timeline(d):
        return TimelineParser.draw(d, paint: theme)
    case let .journey(d):
        return JourneyParser.draw(d, paint: theme)
    case let .git(d):
        return GitParser.draw(d, paint: theme)
    case let .quadrant(d):
        return QuadrantParser.draw(d, paint: theme)
    case let .xyChart(d):
        return XYChartParser.draw(d, paint: theme)
    case let .sankey(d):
        return SankeyParser.draw(d, paint: theme)
    case let .block(d):
        return BlockParser.draw(d, paint: theme)
    case let .requirement(d):
        return RequirementParser.draw(d, paint: theme, hover: hover)
    case let .c4(d):
        return C4Parser.draw(d, paint: theme, hover: hover)
    }
}
