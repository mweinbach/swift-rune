import Foundation
import RuneMotion

/// Range-based strikethrough specification attached via `El.strike` / `El.strikes` (`rune::el::text::strike`).
internal struct ElStrikeSpec: Sendable, Hashable {
    var byteRange: Range<Int>
    var color: Color?
}

private enum ShellElExtrasKey {
    static let spanRadius = "shell.spanRadius"
    static let strikes = "shell.strikes"
    static let wrapAnywhere = "shell.wrapAnywhere"
    static let revealWordFade = "shell.revealWordFade"
    static let outline = "shell.elOutline"
    static let paintAlpha = "shell.paintAlpha"
    static let layerOpacity = "shell.layerOpacity"
    static let mark = "shell.mark"
    static let timeScale = "shell.timeScale"
}

extension El {
    // MARK: - el/motion.rs

    /// Orders painting and hit testing among siblings (`El::paint_order`).
    ///
    /// Higher values paint above lower values; equal values preserve tree order. Unlike `raise`,
    /// this stays within the parent's clipping and layer scope.
    public func paintOrder(_ order: Int16) -> Self {
        z(Int(order))
    }

    /// Springs the leading edge on `lead` and the trailing edge on `trail` when traveling (`El::lead`).
    public func lead(_ lead: Spring, _ trail: Spring) -> Self {
        var copy = self
        let base = copy.layoutAnim ?? LayoutAnim(spring: trail)
        copy.layoutAnim = base.lead(lead, trail)
        return copy
    }

    // MARK: - el/text.rs

    /// Corner radius in points of rounded `RichSpan` background chips (`El::span_radius`, default `4.0`).
    public func spanRadius(_ radius: Float) -> Self {
        guard isTextElement, radius.isFinite else { return self }
        var copy = self
        copy.runtimeExtras[ShellElExtrasKey.spanRadius] = max(0, radius)
        return copy
    }

    /// Adds a strikethrough segment across UTF-8 byte range `byteRange` (`El::strike`).
    ///
    /// When `color` is `nil`, the segment inherits the overlapping span color or the text's color.
    public func strike(_ byteRange: Range<Int>, _ color: Color? = nil) -> Self {
        guard isTextElement, byteRange.lowerBound < byteRange.upperBound else { return self }
        var copy = self
        var list = (copy.runtimeExtras[ShellElExtrasKey.strikes] as? [ElStrikeSpec]) ?? []
        list.append(ElStrikeSpec(byteRange: max(0, byteRange.lowerBound)..<byteRange.upperBound, color: color))
        copy.runtimeExtras[ShellElExtrasKey.strikes] = list
        return copy
    }

    /// Adds multiple strikethrough segments `(byteRange, color)` (`El::strikes`).
    public func strikes(_ items: [(Range<Int>, Color?)]) -> Self {
        var copy = self
        for (range, color) in items {
            copy = copy.strike(range, color)
        }
        return copy
    }

    /// Wraps text at the element's width, breaking inside unbroken tokens when needed (`El::wrap_anywhere`).
    internal func applyWrapAnywhere(_ enabled: Bool = true) -> Self {
        if hasEditLens && textStyle.wrap == .noWrap {
            return self
        }
        guard isTextElement else { return self }
        var copy = self
        if enabled {
            copy.textStyle.wrap = .wrap
        }
        copy.textStyle.wrapAnywhere = enabled
        copy.runtimeExtras["htmlWrapAnywhere"] = enabled
        copy.runtimeExtras[ShellElExtrasKey.wrapAnywhere] = enabled
        return copy
    }

    /// Whether this element is configured to wrap text (`El::wraps`).
    public func wraps() -> Bool {
        isTextElement && textStyle.wrap == .wrap
    }

    /// Enables streaming word-by-word reveal over `wordFade` seconds per word (`El::reveal`).
    /// Negative values disable word reveal, matching upstream `El::reveal(-1.0)`.
    public func reveal(wordFade: Float) -> Self {
        guard isTextElement else { return self }
        let value = wordFade.isFinite ? wordFade : 0
        var copy = self
        copy.textReveal = value
        if copy.runtimeExtras[ShellElExtrasKey.revealWordFade] != nil {
            copy.runtimeExtras.removeValue(forKey: ShellElExtrasKey.revealWordFade)
        }
        return copy
    }

    /// Sets the text selection highlight color (`El::selection_color`).
    public func selectionColor(_ color: Color) -> Self {
        var copy = self
        copy.selectionColor = color
        return copy
    }

    // MARK: - el/visuals.rs

    /// Shorthand outer drop shadow offset by `(0, y)` with CSS `blur` radius (`El::shadow`).
    public func shadow(y: Float, blur: Float, color: Color) -> Self {
        shadow(Shadow(x: 0, y: y, blur: blur, spread: 0, color: color, inset: false))
    }

    /// Draws an un-blurred ring `offset` points outside the border box (`El::outline`).
    public func outline(width: Float, offset: Float, color: Color) -> Self {
        let w = width.isFinite ? max(0, width) : 0
        let off = offset.isFinite ? offset : 0
        var copy = self
        copy.runtimeExtras[ShellElExtrasKey.outline] = Outline(width: w, offset: off, color: color)
        return copy
    }

    /// Dims each paint leaf in the currently built subtree independently without an offscreen layer (`El::dim`).
    public func dim(_ alpha: Float) -> Self {
        let clamped = alpha.isFinite ? alpha.clamped(to: 0...1) : 1.0
        func apply(_ node: inout El<State>, factor: Float) {
            if factor < 1.0 || node.runtimeExtras[ShellElExtrasKey.paintAlpha] != nil {
                let prev = (node.runtimeExtras[ShellElExtrasKey.paintAlpha] as? Float) ?? 1.0
                node.runtimeExtras[ShellElExtrasKey.paintAlpha] = prev * factor
            }
            for i in node.children.indices {
                apply(&node.children[i], factor: factor)
            }
        }
        var copy = self
        apply(&copy, factor: clamped)
        return copy
    }

    /// Fades this subtree as a single composited offscreen layer (`El::layer_opacity`).
    public func layerOpacity(_ alpha: Float) -> Self {
        let clamped = alpha.isFinite ? alpha.clamped(to: 0...1) : 1.0
        var copy = self
        if clamped < 1.0 || copy.runtimeExtras[ShellElExtrasKey.layerOpacity] != nil {
            let prev = (copy.runtimeExtras[ShellElExtrasKey.layerOpacity] as? Float) ?? 1.0
            copy.runtimeExtras[ShellElExtrasKey.layerOpacity] = prev * clamped
        }
        return copy
    }

    /// Tags this element's render instances (and descendants until overridden) for compositors (`El::mark`).
    public func mark(_ mark: UInt32) -> Self {
        var copy = self
        if mark != 0 || copy.runtimeExtras[ShellElExtrasKey.mark] != nil {
            copy.runtimeExtras[ShellElExtrasKey.mark] = mark
        }
        return copy
    }

    /// Scales animation time for this element and its subtree (`El::time_scale`).
    public func timeScale(_ k: Float) -> Self {
        let s = (k.isFinite && k >= 0) ? k : 1.0
        var copy = self
        if s != 1.0 || copy.runtimeExtras[ShellElExtrasKey.timeScale] != nil {
            copy.runtimeExtras[ShellElExtrasKey.timeScale] = s
        }
        return copy
    }

    // MARK: - Internal Accessors

    private var isTextElement: Bool {
        plainText != nil || richSpans != nil || liveText != nil || hasEditLens
    }

    internal var elSpanRadius: Float {
        (runtimeExtras[ShellElExtrasKey.spanRadius] as? Float) ?? TextDecorations.spanRadius
    }

    internal var elStrikes: [ElStrikeSpec] {
        (runtimeExtras[ShellElExtrasKey.strikes] as? [ElStrikeSpec]) ?? []
    }

    internal var isWrapAnywhere: Bool {
        (runtimeExtras[ShellElExtrasKey.wrapAnywhere] as? Bool)
            ?? (runtimeExtras["htmlWrapAnywhere"] as? Bool)
            ?? false
    }

    internal var elRevealWordFade: Float? {
        (runtimeExtras[ShellElExtrasKey.revealWordFade] as? Float) ?? (textReveal >= 0 ? textReveal : nil)
    }

    internal var elOutline: Outline? {
        runtimeExtras[ShellElExtrasKey.outline] as? Outline
    }

    internal var elPaintAlpha: Float {
        (runtimeExtras[ShellElExtrasKey.paintAlpha] as? Float) ?? 1.0
    }

    internal var elLayerOpacity: Float {
        (runtimeExtras[ShellElExtrasKey.layerOpacity] as? Float) ?? 1.0
    }

    internal var elMark: UInt32? {
        runtimeExtras[ShellElExtrasKey.mark] as? UInt32
    }

    internal var elTimeScale: Float {
        (runtimeExtras[ShellElExtrasKey.timeScale] as? Float) ?? 1.0
    }
}
