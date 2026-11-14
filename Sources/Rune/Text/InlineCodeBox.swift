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
    /// the baseline: the line box is the largest reach above plus the largest below, so a line
    /// holding code is `lineHeightPx + over + under` tall and its baseline `over` lower.
    public static func lineGrowth(
        strut: (ascentPx: Float, descentPx: Float),
        code: [(ascentPx: Float, descentPx: Float)],
        lineHeightPx: Float
    ) -> (over: Float, under: Float) {
        guard !code.isEmpty, lineHeightPx > 0 else { return (0, 0) }
        let s = quantizedBox(ascentPx: strut.ascentPx, descentPx: strut.descentPx, lineHeightPx: lineHeightPx)
        var over = s.over
        var under = s.under
        for c in code {
            let b = quantizedBox(ascentPx: c.ascentPx, descentPx: c.descentPx, lineHeightPx: lineHeightPx)
            over = max(over, b.over)
            under = max(under, b.under)
        }
        return (max(0, over - s.over), max(0, under - s.under))
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
