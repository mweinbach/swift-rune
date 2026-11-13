import Foundation
import RuneMotion

extension Shadow {
    /// A CALayer shadow (`shadowRadius` `radius`, `shadowOffset` `(x, y)` with y down,
    /// `shadowColor` with `shadowOpacity` folded into `color`). Core Animation blur has
    /// standard deviation ~`radius`, so `blur` is `2 * radius` (`Shadow::core_animation`).
    public static func coreAnimation(_ x: Float, _ y: Float, _ radius: Float, _ color: Color) -> Shadow {
        Shadow(x: x, y: y, blur: 2.0 * radius, spread: 0.0, color: color)
    }

    /// Labeled overload for `Shadow.coreAnimation`.
    public static func coreAnimation(x: Float = 0, y: Float, radius: Float, color: Color) -> Shadow {
        coreAnimation(x, y, radius, color)
    }
}

extension El {
    // MARK: - Rich Text & Pill Styling

    /// Sets the visual palette for rich inline marks (`code`, `link`) and paragraph blocks
    /// (`quote`, `code block`, list markers) on a `textInput` or `rich` element (`El::rich_style`).
    public func richStyle(_ style: RichStyle) -> Self {
        var c = self
        c.richStyleSpec = style
        return c
    }

    /// Sets the default chip background and optional label/icon color for inline pills (`El::pill_colors`).
    public func pillColors(_ bg: Color, _ fg: Color? = nil) -> Self {
        var c = self
        c.pillColorsSpec = (bg, fg)
        return c
    }

    /// Sets the leading icon lookup closure for inline pills by pill id (`El::pill_icon`).
    public func pillIcon(_ icon: @escaping (String) -> SVGIcon?) -> Self {
        var c = self
        c.pillIconLookup = icon
        return c
    }

    /// Sets the per-id style lookup closure for inline pills (`El::pill_style`).
    public func pillStyle(_ style: @escaping (String) -> PillStyle) -> Self {
        var c = self
        c.pillStyleLookup = style
        return c
    }

    // MARK: - Input Modes

    /// Keeps a text input to one line: long text scrolls horizontally under the caret instead of wrapping (`El::single_line`).
    public func singleLine(_ on: Bool = true) -> Self {
        var c = self
        c.isSingleLineInput = on
        if c.handlers.editLens != nil {
            c.textStyle.wrap = on ? .noWrap : .wrap
        }
        return c
    }

    /// Opts a `textInput` commit in to animated layout (`El::animate_edit_layout`) rather than snapping edits via `Tx.instant()`.
    public func animateEditLayout(_ on: Bool = true) -> Self {
        var c = self
        c.animateEditLayoutEnabled = on
        return c
    }

    // MARK: - Icon Styling

    /// Paints a multi-color icon as a monochrome silhouette using this element's text color (`El::icon_one_color`).
    public func iconOneColor(_ on: Bool = true) -> Self {
        var c = self
        c.isIconOneColor = on
        return c
    }

    /// Turns an `icon(...)` element's icon by `radians` clockwise without rotating its box (`El::icon_rotation`).
    public func iconRotation(_ radians: Float) -> Self {
        var c = self
        c.iconRotation = radians.isFinite ? radians : 0.0
        return c
    }

    // MARK: - Hover & Layering

    /// `hoverGroup()`, which follows keyboard focus as well (`El::hover_group_focus`).
    public func hoverGroupFocus() -> Self {
        var copy = hoverGroup()
        copy.runtimeExtras[RenderExtrasKey.hoverGroupFocus] = true
        return copy
    }

    /// Paints this element and its subtree above everything else in the window and gives it hit priority (`El::raise`).
    public func raise(_ on: Bool = true) -> Self {
        var c = self
        c.isRaised = on
        return c
    }

    // MARK: - Motion Curves & Flags

    /// The X axis springs faster (`0.78×` duration) when this element resizes or travels (`El::width_leads`).
    public func widthLeads(_ on: Bool = true) -> Self {
        var c = self
        c.isWidthLeads = on
        return c
    }

    /// Holds an animated container at its landing width so text wraps once while sliding (`El::hold_landing_width`).
    public func holdLandingWidth(_ on: Bool = true) -> Self {
        var c = self
        c.holdLandingWidthEnabled = on
        return c
    }

    /// Curve used when `offset` changes (`El::offset_motion`).
    public func offsetMotion(_ anim: Anim<Vec2>) -> Self {
        var c = self
        c.offsetMotionAnim = anim
        return c
    }

    public func offsetMotion(_ spring: Spring, delay: TimeInterval = 0) -> Self {
        offsetMotion(Anim(curve: .spring(spring), delay: Float(delay)))
    }

    /// Curve used when `opacity` changes (`El::opacity_motion`).
    public func opacityMotion(_ anim: Anim<Float>) -> Self {
        var c = self
        c.opacityMotionAnim = anim
        return c
    }

    public func opacityMotion(_ spring: Spring, delay: TimeInterval = 0) -> Self {
        opacityMotion(Anim(curve: .spring(spring), delay: Float(delay)))
    }

    /// Curve used when `scale` changes (`El::scale_motion`).
    public func scaleMotion(_ anim: Anim<Vec2>) -> Self {
        var c = self
        c.scaleMotionAnim = anim
        return c
    }

    public func scaleMotion(_ spring: Spring, delay: TimeInterval = 0) -> Self {
        scaleMotion(Anim(curve: .spring(spring), delay: Float(delay)))
    }

    /// Curve used when `rotate` changes (`El::rotate_motion`).
    public func rotateMotion(_ anim: Anim<Float>) -> Self {
        var c = self
        c.rotateMotionAnim = anim
        return c
    }

    public func rotateMotion(_ spring: Spring, delay: TimeInterval = 0) -> Self {
        rotateMotion(Anim(curve: .spring(spring), delay: Float(delay)))
    }

    // MARK: - Text Layout, Case, Rings, Truncation & Runs

    /// Transforms how text glyphs are displayed without changing copied text or `ElementInfo.text` (`El::text_case`).
    public func textCase(_ mode: TextCase) -> Self {
        var c = self
        c.textCaseValue = mode
        return c
    }

    /// Draws an inset `color` border ring `width` points wide inside the background of UTF-8 bytes `byteRange` (`El::span_ring`).
    public func spanRing(_ byteRange: Range<Int>, _ color: Color, width: Float = 1.0) -> Self {
        guard !byteRange.isEmpty, width > 0, width.isFinite else { return self }
        var c = self
        c.spanRingsSpec.append((byteRange, color, width))
        return c
    }

    /// Batch overload for `spanRing`.
    public func spanRings(_ items: [(Range<Int>, Color, Float)]) -> Self {
        var c = self
        for (r, col, w) in items where !r.isEmpty && w > 0 && w.isFinite {
            c.spanRingsSpec.append((r, col, w))
        }
        return c
    }

    /// Keeps this text's height unrounded at its lines' exact fractional height (`El::exact_lines`, default).
    public func exactLines() -> Self {
        var c = self
        c.textStyle.exactLines = true
        return c
    }

    /// Rounds this text's height up to whole device pixels (`El::rounded_lines`).
    public func roundedLines() -> Self {
        var c = self
        c.textStyle.exactLines = false
        return c
    }

    private func setOneLineElide(_ elide: TextElide) -> Self {
        if handlers.editLens != nil { return self }
        var c = self
        c.textStyle.wrap = .ellipsis
        c.textStyle.elide = elide
        c.textStyle.maxLines = 0
        c.isTruncateFadeEnabled = false
        return c.shrink(1).minW(0)
    }

    /// Single-line truncation keeping both ends (`"…"` in the middle, `El::truncate_middle`).
    public func truncateMiddle() -> Self {
        setOneLineElide(.middle)
    }

    /// Single-line truncation keeping the end (`"…"` at the start, `El::truncate_head`).
    public func truncateHead() -> Self {
        setOneLineElide(.head)
    }

    /// Clamps wrapped text after `lines` lines with `"…"` ending the last (`El::max_lines`).
    public func maxLines(_ lines: Int) -> Self {
        if handlers.editLens != nil { return self }
        var c = self
        c.textStyle.wrap = .wrap
        c.textStyle.maxLines = max(0, lines)
        c.isTruncateFadeEnabled = false
        return c
    }

    /// One line clipped with a 1.5 em trailing fade when overflowing (`El::truncate_fade`).
    public func truncateFade() -> Self {
        truncateFadeWidth(1.5)
    }

    /// One line clipped with a trailing fade `em` ems wide when overflowing (`El::truncate_fade_width`).
    public func truncateFadeWidth(_ em: Float) -> Self {
        var c = self
        c.textStyle.wrap = .noWrap
        c.textStyle.maxLines = 0
        c.isTruncateFadeEnabled = true
        c.truncateFadeEm = max(0, em)
        return c.shrink(1).minW(0)
    }

    /// Shapes this text cell as the grapheme slice at UTF-8 byte `at` within `run`, keeping run kerning (`El::advance_in`).
    public func advanceIn(_ run: TextRun, at byteOffset: Int) -> Self {
        var c = self
        c.advanceInRun = (run, max(0, byteOffset))
        return c
    }
}
