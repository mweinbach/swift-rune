import Foundation
import Rune

// MARK: - Searchable Drawing (`rune_mermaid::drawing`)

/// Searchable label runs from a laid-out Mermaid diagram, not the syntax that produced it.
///
/// One prepared layout. Its title and labels can be indexed once, then drawn again with
/// different text highlights without parsing the source or laying the diagram out again
/// (`rune_mermaid::DrawingModel`).
public struct MermaidDrawingModel: Sendable {
    /// The shared scene, compared by identity like upstream's `Rc<Scene>`.
    let shared: MermaidScenes.Shared
    let style: MermaidTheme

    init(shared: MermaidScenes.Shared, style: MermaidTheme) {
        self.shared = shared
        self.style = style
    }

    /// `(element key, shown text)` in drawing order. Includes a displayed title, but not
    /// node IDs, source comments or the duplicate paint used to light a label on hover.
    public func labels() -> [(key: String, text: String)] {
        let scene = shared.scene
        var out: [(key: String, text: String)] = []
        out.reserveCapacity(scene.labels.count + 1)
        if let title = scene.title {
            out.append((key: "title", text: title))
        }
        for (lk, l) in zip(scene.labelKeys, scene.labels) {
            out.append((key: lk.key, text: l.text))
        }
        return out
    }

    /// Whether text ranges for `other` still describe this exact layout.
    public func sameLayout(_ other: MermaidDrawingModel) -> Bool {
        shared === other.shared
    }

    /// Draw with UTF-8 byte ranges local to each label. Keys are the ones returned by
    /// ``labels()``. A hover copy uses the same marks as the label underneath it.
    public func draw<State>(_ marks: (String) -> [TextHighlight]) -> MermaidDrawing<State> {
        withoutActuallyEscaping(marks) { marks in
            let (el, size): (El<State>, Vec2) = shared.scene.drawing(paint: style, marks: marks)
            return MermaidDrawing(el: el, size: size, surface: style.surface, surfaceBorder: style.surfaceBorder)
        }
    }
}

/// Alias matching upstream `DrawingModel`.
public typealias DrawingModel = MermaidDrawingModel

/// Prepare the same layout as ``renderMermaidDrawing(_:theme:hover:)``, retaining it for text
/// lookup (`rune_mermaid::prepare_drawing`).
public func prepareMermaidDrawing(
    _ source: String,
    theme: MermaidTheme = .neutral(dark: false),
    hover: (MermaidHover, Color)? = nil
) -> MermaidDrawingModel? {
    let resolved = resolvedHover(hover, theme: theme)
    guard let shared = MermaidScenes.built(source, theme: theme, hover: resolved, prev: nil).shared else {
        return nil
    }
    return MermaidDrawingModel(shared: shared, style: theme)
}

/// `prepare_drawing(src, style, hover, color)` with upstream's argument shape: `.off` draws
/// no hover groups at all.
public func prepareDrawing(
    _ source: String,
    style: MermaidTheme,
    hover: MermaidHover,
    color: Color
) -> MermaidDrawingModel? {
    let pair: (MermaidHover, Color)? = hover != .off ? (hover, color) : nil
    guard let shared = MermaidScenes.built(source, theme: style, hover: pair, prev: nil).shared else {
        return nil
    }
    return MermaidDrawingModel(shared: shared, style: style)
}
