import Foundation
import Rune
import RuneMermaid

/// Kit-styled Mermaid diagram integration (`rune_kit::mermaid`) powered by `RuneMermaid`.
public enum KitMermaid {
    public typealias DiagramStyle = MermaidTheme
    public typealias Drawing<State> = MermaidDrawing<State>
    public typealias Hover = MermaidHover

    /// Re-export of `RuneMermaid`'s searchable prepared layout (`rune_kit::mermaid::DrawingModel`).
    public typealias DrawingModel = MermaidDrawingModel

    /// Whether `source` parses as a supported Mermaid diagram.
    public static func supported(_ source: String) -> Bool {
        supportedMermaid(source)
    }

    /// Whether a partial source may grow into a supported diagram.
    public static func mayDraw(_ source: String) -> Bool {
        mayDrawMermaid(source)
    }

    /// Whether `source` parses as a valid Mermaid diagram.
    public static func canRender(_ source: String) -> Bool {
        supported(source)
    }

    /// Prepare the drawn label runs for a viewer that searches and highlights a diagram
    /// (`rune_kit::mermaid::prepare`): `style`'s diagram paint laid out for a card `maxWidth`
    /// points wide, with the same hover as the diagram card.
    public static func prepare(_ source: String, style: MarkdownStyle, maxWidth: Float) -> MermaidDrawingModel? {
        let paint = style.diagram
        var full = style.mermaidTheme()
        full.maxWidth = maxWidth
        return prepareDrawing(source, style: full, hover: hover(paint), color: paint.hover)
    }

    /// Renders a diagram card using the same paint and interaction as a Markdown fence.
    public static func render<State>(_ source: String, style: MarkdownStyle) -> El<State>? {
        diagram(source, style: style, streaming: false, open: false)
    }

    static func diagram<State>(_ source: String, style: MarkdownStyle, streaming: Bool, open: Bool) -> El<State>? {
        let theme = style.mermaidTheme()
        let interaction = (hover(style.diagram), style.diagram.hover)
        let card: El<State>?
        if !streaming {
            card = renderMermaid(source, theme: theme, hover: interaction)
        } else if open {
            card = renderMermaidStreaming(source, theme: theme, hover: interaction)
        } else {
            card = renderMermaidStreamed(source, theme: theme, hover: interaction)
        }
        return card.map { figure($0, source: source) }
    }

    /// Renders a frameless diagram with the Markdown paint at the viewer's width.
    public static func drawing<State>(_ source: String, style: MarkdownStyle, maxWidth: Float) -> Drawing<State>? {
        var theme = style.mermaidTheme()
        theme.maxWidth = maxWidth
        return drawing(source, theme: theme, hover: (hover(style.diagram), style.diagram.hover))
    }

    fileprivate static func drawing<State>(_ source: String, theme: MermaidTheme, hover: (MermaidHover, Color)) -> Drawing<State>? {
        guard var drawing: Drawing<State> = renderMermaidDrawing(source, theme: theme, hover: hover) else {
            return nil
        }
        drawing.el = figure(drawing.el, source: source)
        return drawing
    }

    /// What hovering a node lights up for `paint` (`rune_kit::mermaid::hover`): nothing when the
    /// hover colour is fully transparent, else its edges, or its neighbours too.
    static func hover(_ paint: MarkdownDiagramPaint) -> MermaidHover {
        switch (paint.hover.a > 0.0, paint.hoverNeighbours) {
        case (false, _): return .off
        case (true, false): return .edges
        case (true, true): return .neighbours
        }
    }

    /// Human-readable accessible label for the diagram kind in `source`.
    public static func kindLabel(_ source: String) -> String {
        var remaining = source.unicodeScalars[...]
        var word: Substring.UnicodeScalarView
        repeat {
            remaining = remaining.drop(while: \.properties.isWhitespace)
            word = remaining.prefix { !$0.properties.isWhitespace }
            remaining = remaining[word.endIndex...]
        } while word.starts(with: "%%".unicodeScalars)

        var normalized = String(word)
        while normalized.hasSuffix("-beta") {
            normalized.removeLast("-beta".count)
        }
        while normalized.hasSuffix("-v2") {
            normalized.removeLast("-v2".count)
        }
        switch normalized {
        case "graph", "flowchart": return "Flowchart"
        case "sequenceDiagram": return "Sequence diagram"
        case "stateDiagram": return "State diagram"
        case "classDiagram": return "Class diagram"
        case "erDiagram": return "Entity relationship diagram"
        case "gantt": return "Gantt chart"
        case "pie": return "Pie chart"
        case "mindmap": return "Mind map"
        case "timeline": return "Timeline"
        case "journey": return "User journey"
        case "gitGraph": return "Git graph"
        case "quadrantChart": return "Quadrant chart"
        case "xychart": return "XY chart"
        case "sankey": return "Sankey diagram"
        case "block": return "Block diagram"
        case "requirementDiagram": return "Requirement diagram"
        default:
            return normalized.hasPrefix("C4") ? "C4 diagram" : "Diagram"
        }
    }

    /// Shared by standalone diagrams, frameless drawings, and Markdown fences.
    fileprivate static func figure<State>(_ element: El<State>, source: String) -> El<State> {
        let scalars = source.unicodeScalars.drop(while: \.properties.isWhitespace)
        let last = scalars.lastIndex { !$0.properties.isWhitespace }
        let description = last.map { String(scalars[...$0]) } ?? ""
        return element.role(.figure).label(kindLabel(source)).description(description)
    }
}

extension Kit {
    /// Builds a `MermaidTheme` derived from this `Kit`'s surface, border, and ink tokens (`markdown/style.rs`).
    public func mermaidTheme(
        maxWidth: Float = 680,
        minScale: Float = 0.6
    ) -> MermaidTheme {
        var theme = MermaidTheme.neutral(dark: dark).minScale(minScale)
        theme.text = c.textBase
        theme.muted = c.textMuted
        theme.surface = c.bgBase
        theme.surfaceBorder = c.borderMuted
        theme.nodeFill = c.layer01
        theme.nodeBorder = alpha(c.textBase, 0.2)
        theme.line = alpha(c.textBase, 0.42)
        theme.clusterFill = alpha(c.textBase, dark ? 0.04 : 0.025)
        theme.noteFill = c.warning.bg
        theme.noteBorder = c.warning.border
        theme.maxWidth = maxWidth
        return theme
    }

    /// Renders a Mermaid diagram card styled with `Kit` tokens, returning `nil` when unsupported/invalid.
    public func mermaid<State>(
        _ source: String,
        maxWidth: Float = 680,
        minScale: Float = 0.6,
        hoverNeighbours: Bool = false
    ) -> El<State>? {
        let theme = mermaidTheme(maxWidth: maxWidth, minScale: minScale)
        let hover: (MermaidHover, Color) = (hoverNeighbours ? .neighbours : .edges, alpha(c.textBase, 0.9))
        guard let card: El<State> = renderMermaid(source, theme: theme, hover: hover) else {
            return nil
        }
        return KitMermaid.figure(card, source: source)
    }

    /// Renders a frameless `MermaidDrawing` styled with `Kit` tokens for lightbox or custom containers.
    public func mermaidDrawing<State>(
        _ source: String,
        maxWidth: Float = 1024,
        minScale: Float = 0.6,
        hoverNeighbours: Bool = false
    ) -> MermaidDrawing<State>? {
        let theme = mermaidTheme(maxWidth: maxWidth, minScale: minScale)
        let hover: (MermaidHover, Color) = (hoverNeighbours ? .neighbours : .edges, alpha(c.textBase, 0.9))
        return KitMermaid.drawing(source, theme: theme, hover: hover)
    }

    /// Renders a Mermaid diagram when valid, or falls back to a syntax-highlighted code block.
    public func mermaidOrCode<State>(
        key: String = "mermaid",
        source: String,
        maxWidth: Float = 680
    ) -> El<State> {
        if let diagram: El<State> = mermaid(source, maxWidth: maxWidth) {
            return diagram.key(key)
        }
        return codeBlock(key: key, code: source, language: "mermaid", showLineNumbers: false)
    }
}
