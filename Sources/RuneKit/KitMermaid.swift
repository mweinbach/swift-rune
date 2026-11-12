import Foundation
import Rune
import RuneMermaid

/// Kit-styled Mermaid diagram integration (`rune_kit::mermaid`) powered by `RuneMermaid`.
public enum KitMermaid {
    /// Whether `source` starts with a Mermaid diagram type supported by `RuneMermaid`.
    public static func supported(_ source: String) -> Bool {
        supportedMermaid(source)
    }

    /// Whether `source` parses as a valid Mermaid diagram.
    public static func canRender(_ source: String) -> Bool {
        canRenderMermaid(source)
    }

    /// Human-readable accessible label for the diagram kind in `source`.
    public static func kindLabel(_ source: String) -> String {
        let first = source
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .first(where: { !$0.hasPrefix("%%") }) ?? ""
        var normalized = first
        if normalized.hasSuffix("-beta") {
            normalized.removeLast("-beta".count)
        }
        if normalized.hasSuffix("-v2") {
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
        return card
            .label(KitMermaid.kindLabel(source))
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
        return renderMermaidDrawing(source, theme: theme, hover: hover)
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
