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

    /// `hoverGroup()`, which follows keyboard focus as well now (`El::hover_group_focus`, an alias
    /// of `hoverGroup` since upstream 4e215eac #726).
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

    /// Truncates an overflowing line with an ellipsis at its end (`El::truncate`).
    public func truncate() -> Self {
        setOneLineElide(.end)
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

    // MARK: - El-Owned Slice 1 Builders (`gaps`, `isolate`)

    /// Separate row and column gaps (`El::gaps`).
    public func gaps(_ row: Float, _ column: Float) -> Self {
        var c = self
        c.layout.rowGap = max(0, row)
        c.layout.columnGap = max(0, column)
        return c
    }

    /// Labeled separate row and column gaps (`El::gaps`).
    public func gaps(row: Float, column: Float) -> Self {
        gaps(row, column)
    }

    /// Marks UTF-8 byte `range` of static text as a UAX #9 directional isolate (`El::isolate`).
    public func isolate(_ range: Range<Int>, _ dir: Direction) -> Self {
        guard handlers.editLens == nil else { return self }
        guard plainText != nil || richSpans != nil else { return self }
        let content = plainText ?? richSpans?.map(\.text).joined() ?? ""
        let len = content.utf8.count
        let a = range.lowerBound
        let b = range.upperBound
        guard a >= 0, a < b, b <= len,
              InlineIconLayout.isUTF8Boundary(a, in: content),
              InlineIconLayout.isUTF8Boundary(b, in: content) else {
            return self
        }
        guard !isolatesSpec.contains(where: { $0.range.lowerBound < b && a < $0.range.upperBound }) else {
            return self
        }
        var c = self
        var list = c.isolatesSpec
        let idx = list.firstIndex(where: { $0.range.lowerBound >= a }) ?? list.endIndex
        list.insert((a..<b, dir), at: idx)
        c.isolatesSpec = list
        return c
    }

    /// Inserts queued directional isolate marks into text and shifts all byte ranges idempotently.
    internal func applyingIsolates() -> Self {
        let isolates = isolatesSpec
        guard !isolates.isEmpty,
              handlers.editLens == nil,
              advanceInRun == nil,
              !(isSecure && !isRevealed) else {
            return self
        }
        let authored = plainText ?? richSpans?.map(\.text).joined() ?? ""
        let utf8 = Array(authored.utf8)
        let markLen = 3 // LRI (U+2066), RLI (U+2067), FSI (U+2068), PDI (U+2069) are all 3 UTF-8 bytes.
        var marked = String()
        marked.reserveCapacity(utf8.count + isolates.count * markLen * 2)
        var cursor = 0
        for iso in isolates {
            let a = min(iso.range.lowerBound, utf8.count)
            let b = min(max(a, iso.range.upperBound), utf8.count)
            if a > cursor {
                marked.append(String(decoding: utf8[cursor..<a], as: UTF8.self))
            }
            switch iso.dir {
            case .ltr: marked.append("\u{2066}")
            case .rtl: marked.append("\u{2067}")
            case .auto: marked.append("\u{2068}")
            }
            if b > a {
                marked.append(String(decoding: utf8[a..<b], as: UTF8.self))
            }
            marked.append("\u{2069}")
            cursor = b
        }
        if cursor < utf8.count {
            marked.append(String(decoding: utf8[cursor..<utf8.count], as: UTF8.self))
        }

        func shiftPoint(_ p: Int, openAtP: Bool, closeAtP: Bool) -> Int {
            var opens = 0
            var closes = 0
            for iso in isolates {
                if iso.range.lowerBound < p || (openAtP && iso.range.lowerBound == p) { opens += 1 }
                if iso.range.upperBound < p || (closeAtP && iso.range.upperBound == p) { closes += 1 }
            }
            return p + markLen * (opens + closes)
        }

        func remapRange(_ range: Range<Int>) -> Range<Int> {
            let start = range.lowerBound
            let end = range.upperBound
            let within = isolates.first { $0.range.lowerBound <= start && end <= $0.range.upperBound }
            let s = shiftPoint(start, openAtP: within.map { $0.range.lowerBound == start } ?? false, closeAtP: true)
            let e = shiftPoint(end, openAtP: false, closeAtP: within.map { $0.range.upperBound != end } ?? true)
            return s..<max(s, e)
        }

        var c = self
        if c.plainText != nil {
            c.plainText = marked
        }
        if !c.textLinks.isEmpty {
            c.textLinks = c.textLinks.map { link in
                var l = link
                l.byteRange = remapRange(link.byteRange)
                return l
            }
        }
        if !c.spanRingsSpec.isEmpty {
            c.spanRingsSpec = c.spanRingsSpec.map { (remapRange($0.range), $0.color, $0.width) }
        }
        if let hls = c.textHighlights, !hls.isEmpty {
            c.textHighlights = hls.map { h in
                var nh = h
                nh.byteRange = remapRange(h.byteRange)
                return nh
            }
        }
        var pills = c.pillChips
        if !pills.isEmpty {
            pills = pills.map { chip in
                var p = chip
                p.range = remapRange(chip.range)
                return p
            }
            c.runtimeExtras["pillChips"] = pills
        }
        var icons = c.inlineIcons
        if !icons.isEmpty {
            icons = icons.map { ic in
                var nic = ic
                nic.byteOffset = remapRange(ic.byteOffset..<(ic.byteOffset + 1)).lowerBound
                return nic
            }
            c.runtimeExtras["inlineIcons"] = icons
        }
        var uncopied = c.uncopiedRanges.map(remapRange)
        for (k, iso) in isolates.enumerated() {
            let before = 2 * markLen * k
            let openRange = (iso.range.lowerBound + before)..<(iso.range.lowerBound + before + markLen)
            let closeRange = (iso.range.upperBound + before + markLen)..<(iso.range.upperBound + before + 2 * markLen)
            let openAt = uncopied.firstIndex(where: { $0.lowerBound >= openRange.lowerBound }) ?? uncopied.endIndex
            uncopied.insert(openRange, at: openAt)
            let closeAt = uncopied.firstIndex(where: { $0.lowerBound >= closeRange.lowerBound }) ?? uncopied.endIndex
            uncopied.insert(closeRange, at: closeAt)
        }
        c.runtimeExtras[El.uncopiedExtraKey] = uncopied

        if let authoredDefs = c.runtimeExtras["richSpanDefs"] as? [RichSpan] {
            let remappedDefs = authoredDefs.map { sp -> RichSpan in
                var copySpan = sp
                copySpan.byteRange = remapRange(sp.byteRange)
                return copySpan
            }
            if c.plainText == nil {
                c.richSpans = [TextSpan(marked)]
            }
            c = c.spans(remappedDefs)
        } else if let existingSpans = c.richSpans {
            // Preserve arbitrary pre-flattened `[TextSpan]` chunks while emitting zero-glyph isolate marks unstyled.
            let markedUTF8 = Array(marked.utf8)
            var outSpans: [TextSpan] = []
            var srcCursor = 0
            var dstCursor = 0
            for span in existingSpans {
                let len = span.text.utf8.count
                let end = srcCursor + len
                let mapped = remapRange(srcCursor..<end)
                if mapped.lowerBound > dstCursor {
                    let gap = String(decoding: markedUTF8[dstCursor..<mapped.lowerBound], as: UTF8.self)
                    outSpans.append(TextSpan(gap))
                }
                if mapped.upperBound > mapped.lowerBound {
                    var copySpan = span
                    copySpan.text = String(decoding: markedUTF8[mapped.lowerBound..<mapped.upperBound], as: UTF8.self)
                    outSpans.append(copySpan)
                }
                srcCursor = end
                dstCursor = max(dstCursor, mapped.upperBound)
            }
            if dstCursor < markedUTF8.count {
                outSpans.append(TextSpan(String(decoding: markedUTF8[dstCursor..<markedUTF8.count], as: UTF8.self)))
            }
            c.richSpans = outSpans
        }
        c.isolatesSpec = []
        return c
    }
}

/// An effect slot (`El.effect`, `crates/rune/src/el.rs:88`): size it like any box.
public func effect<State>(_ mark: UInt32) -> El<State> {
    El<State>(direction: .row).effect(UInt64(mark))
}

/// `UInt64` convenience overload for free `effect(_:)`.
@_disfavoredOverload
public func effect<State>(_ mark: UInt64) -> El<State> {
    El<State>(direction: .row).effect(mark)
}
