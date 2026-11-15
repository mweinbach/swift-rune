import Foundation
#if canImport(simd)
import simd
#endif

/// Inline code's boxes (upstream `#983`, `text/decorations.rs` and `text/inline_fit.rs`).
///
/// Inline code grows its line as Blink's does: Parley lays each run's box out with quantizing
/// (`BoxMetrics::from_font`: ascent and descent rounded to device px, the half-leading over the
/// text floored), and the line box is the largest reach above the baseline plus the largest
/// below. That is Chromium's rule to the device pixel: at 13/16 IBM Plex Mono reaches 4 under the
/// baseline where Inter reaches 3, so a table cell with code is 17 tall at 1x and 2x (33 device px)
/// and 16 at 1.25x, 1.5x and 1.875x. The smaller spaces that stand for the code's CSS padding have
/// no box in a browser, so theirs never grows the line. Glyphs stay on the shared baseline.
///
/// Inline code's background is its font's content area, as a browser paints an inline element's
/// background: ascent over the baseline and descent under it, each rounded to device px. Other
/// spans balance on the cap height. Whole device pixels.
public enum InlineCodeBox {
    /// A span background's `(top, bottom)` in device px around a baseline at `baselinePx`
    /// (`decorations.rs`): a monospace (inline code) span's content area,
    /// `base.round() - ascent.round()` … `base.round() + descent.round()`; any other span's box
    /// balanced on the cap height, `(base - cap * 1.35).round()` … `(base + cap * 0.55).round()`,
    /// with `cap` the font's cap height or `0.7` of its size when it has none.
    public static func backgroundVertical(
        baselinePx base: Float,
        mono: Bool,
        ascentPx: Float,
        descentPx: Float,
        capHeightPx: Float?,
        fontSizePx: Float
    ) -> (top: Float, bottom: Float) {
        if mono {
            return (base.rounded() - ascentPx.rounded(), base.rounded() + descentPx.rounded())
        }
        let cap = capHeightPx ?? fontSizePx * 0.7
        return ((base - cap * 1.35).rounded(), (base + cap * 0.55).rounded())
    }

    /// Parley's quantized `BoxMetrics::from_font`: a font's box expanded to `lineHeightPx`, as
    /// `(over, under)` the baseline. Ascent and descent round to whole px and the half-leading
    /// above the baseline is floored; `under` is the rest of the line height.
    public static func quantizedBox(ascentPx: Float, descentPx: Float, lineHeightPx: Float) -> (over: Float, under: Float) {
        let ascent = ascentPx.rounded()
        let descent = descentPx.rounded()
        let halfLeading = (lineHeightPx - (ascent + descent)) / 2.0
        let over = ascent + halfLeading.rounded(.down)
        return (over, lineHeightPx - over)
    }

    /// How far (device px) the code boxes on one line reach past the strut's box, above and below
    /// the baseline: the line box is the largest reach above plus the largest below (Parley's
    /// `Extents::add` over the root subtree), so a line holding code is `lineHeightPx + over + under`
    /// tall and its baseline `over` lower. Each code box is quantized at its own line height
    /// (`lineHeightPx` of the box): the paragraph's for a span without a size, and
    /// `LineHeight::FontSizeRelative(line / style.size)` at the span's size otherwise
    /// (`text.rs`, `inline_fit.rs`'s `own`), so 11.7 px code in 13/16 text has a 14.4 px line.
    /// `under` may be fractional (`0.4` there); `lineBoxes` rounds the line's edges as Parley does.
    public static func lineGrowth(
        strut: (ascentPx: Float, descentPx: Float),
        code: [(ascentPx: Float, descentPx: Float, lineHeightPx: Float)],
        lineHeightPx: Float
    ) -> (over: Float, under: Float) {
        guard !code.isEmpty, lineHeightPx > 0 else { return (0, 0) }
        let s = quantizedBox(ascentPx: strut.ascentPx, descentPx: strut.descentPx, lineHeightPx: lineHeightPx)
        var over = s.over
        var under = s.under
        for c in code {
            let b = quantizedBox(ascentPx: c.ascentPx, descentPx: c.descentPx, lineHeightPx: c.lineHeightPx)
            over = max(over, b.over)
            under = max(under, b.under)
        }
        return (max(0, over - s.over), max(0, under - s.under))
    }

    /// One line's box as Parley lays it out with quantizing (`BreakLines::finish_line`, `line_break.rs`).
    public struct LineBox: Equatable, Sendable {
        /// `block_min_coord`: the running `line_y` rounded.
        public var topPx: Float
        /// `block_max_coord`: `(baseline + under).round()`.
        public var bottomPx: Float
        /// `line_height`: the line box's `over + under`, unrounded; `line_y` advances by it.
        public var heightPx: Float

        public init(topPx: Float, bottomPx: Float, heightPx: Float) {
            self.topPx = topPx
            self.bottomPx = bottomPx
            self.heightPx = heightPx
        }
    }

    /// The lines' boxes for each line's `growth` past a strut of `lineHeightPx`, and the layout's
    /// height (`Layout::height`, the sum of the unrounded line heights, which `spec_height` keeps
    /// to 1/64 px). Each line's top is the running `line_y` rounded and its bottom
    /// `top + over + under` rounded, so 13/16 text with 11.7 px code at 1x is a 16.4 px layout whose
    /// first line ends at 16 and whose second starts at 16.
    public static func lineBoxes(growth: [(over: Float, under: Float)], lineHeightPx: Float) -> (lines: [LineBox], heightPx: Float) {
        var lineY: Double = 0
        var out: [LineBox] = []
        out.reserveCapacity(growth.count)
        for g in growth {
            let height = lineHeightPx + g.over + g.under
            let top = Float(lineY.rounded())
            out.append(LineBox(topPx: top, bottomPx: (top + height).rounded(), heightPx: height))
            lineY += Double(height)
        }
        return (out, Float(lineY))
    }

    /// One run's background rect `[l, t, w, h]` (device px) and colour, for `appendMerging`.
    public struct RunBackground: Equatable, Sendable {
        public var rect: SIMD4<Float>
        public var color: Color

        public init(rect: SIMD4<Float>, color: Color) {
            self.rect = rect
            self.color = color
        }
    }

    /// Appends `run`'s background to `out`, merging with the previous one (`decorations.rs`):
    /// touching runs with the same background on one line (a span split by style, or inline code
    /// and its padding spaces in the body font) share one rect, as tall as its widest run, so a
    /// thin run in another font doesn't poke out as a sliver. `pad` is the span's background pad (px).
    public static func appendMerging(_ run: RunBackground, pad: Float = 0, into out: inout [RunBackground], last: inout Int?) {
        let rect = run.rect
        let top = rect.y
        let bot = rect.y + rect.w
        if let i = last {
            let d = out[i].rect
            if out[i].color == run.color,
               d.y < bot,
               top < d.y + d.w,
               abs(d.x + d.z - rect.x - 2.0 * pad) < 1.5 {
                var merged = d
                if rect.z > d.z {
                    merged.y = rect.y
                    merged.w = rect.w
                }
                merged.z = rect.x + rect.z - d.x
                out[i].rect = merged
                return
            }
        }
        last = out.count
        out.append(run)
    }
}
