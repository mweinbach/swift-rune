import Foundation
#if canImport(CoreText)
import CoreText
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Text box geometry shared by layout, measuring and paint, ported from upstream
/// `runtime/commit/text_layout.rs` (`text_width`, `FIT_SLACK`, #934 / #948),
/// `runtime/paint/build.rs` + `paint/content.rs` (`LeafBox::exact_off`, #935 / #963) and
/// `runtime/selection/text_marks.rs` (`pixel_rect`, #935).
public enum TextBoxGeometry {
    /// `px` device pixels rounded up to a 64th of one, the unit Chromium's layout keeps a text
    /// run's width in (`LayoutUnit`): a label is as wide as its glyphs, so what follows it sits
    /// where Chromium puts it, never up to a pixel further on (`text_layout::text_width`, #934).
    @inline(__always)
    public static func textWidth(_ px: Float) -> Float {
        max(0, ((px - 1e-3) * 64.0).rounded(.up)) / 64.0
    }

    /// A text box's width in points from its widest line, `maxLineWidthPt` points at `scale`: as wide
    /// as that line to a 64th of a device pixel, `text_width(w * scale) / scale` (`compute_layout`,
    /// `TextSystem::measure`, #934). The portable (headless) shaper sizes its boxes with it, so it is
    /// compiled and tested on every platform.
    @inline(__always)
    public static func boxWidth(maxLineWidthPt: Float, scale: Float) -> Float {
        let s = max(scale, 1e-4)
        return textWidth(maxLineWidthPt * s) / s
    }

    /// Device px a text may run past the width it wraps at and still fit: `textWidth` can round
    /// a box up to 1e-3 px under its text, and points to device px and back loses a little more,
    /// so a text laid out again in its own shrink-to-fit box would otherwise wrap its last word.
    /// Blink compares both in the same `LayoutUnit`s, where they're equal
    /// (`text_layout::FIT_SLACK`, #948).
    public static let fitSlack: Float = 1.0 / 256.0

    /// The wrap width in points a text lays out at inside `w` points at `scale`: `w * scale +
    /// FIT_SLACK` device px (`compute_layout` / `relayout::lay_out_text`, #948).
    @inline(__always)
    public static func wrapWidth(_ w: Float?, scale: Float) -> Float? {
        guard let w else { return nil }
        let s = max(scale, 1e-4)
        return (w * s + fitSlack) / s
    }

    /// Where a text's exact box rests against where its snapped box rests (device px), its paint
    /// containment's rounding in (`LeafBox::exact_off`, `build.rs`): Blink's text lays out from
    /// the exact place. Zero under an `El.offset` here or above (`pixel_snap::Inherit.shifted`,
    /// #963): a translation, as a CSS transform is, moves a text with its box.
    public static func leafExactOff(
        rest: PixelSnap.Parent?,
        rigid: SIMD2<Float>,
        containPx: SIMD2<Float>,
        shifted: Bool
    ) -> SIMD2<Float> {
        if shifted { return .zero }
        let o = rest?.exactOff(rigid: rigid) ?? .zero
        let c = containPx
        return SIMD2<Float>(
            o.x + (c.x + 0.5).rounded(.down) - c.x,
            o.y + (c.y + 0.5).rounded(.down) - c.y
        )
    }

    /// Whether a text lays out from its exact resting place (`content.rs`): only when its scale is
    /// still and whole (`scale_motion == Still`, `sc ~ 1`) and it isn't a field, which keeps its
    /// snapped box, shared by its caret and selection.
    @inline(__always)
    public static func restsExact(isInput: Bool, scaleStill: Bool, scale: SIMD2<Float>) -> Bool {
        scaleStill && abs(scale.x - 1.0) < 1e-5 && abs(scale.y - 1.0) < 1e-5 && !isInput
    }

    /// A highlight's box (device px `x, y, w, h`) from text at `origin` (points) drawn `k` times
    /// its size, `box` its layout box in points (`x, y, w, h`), its edges on the device grid, as
    /// Chromium snaps a selection's rect: hard-edged wherever the text's origin falls
    /// (`text_marks::pixel_rect`, #935).
    public static func pixelRect(origin: SIMD2<Float>, box: SIMD4<Float>, k: SIMD2<Float>, pxScale s: Float) -> SIMD4<Float> {
        let x0 = ((origin.x + box.x * k.x) * s).rounded()
        let y0 = ((origin.y + box.y * k.y) * s).rounded()
        let x1 = ((origin.x + (box.x + box.z) * k.x) * s).rounded()
        let y1 = ((origin.y + (box.y + box.w) * k.y) * s).rounded()
        return SIMD4<Float>(x0, y0, x1 - x0, y1 - y0)
    }

    /// Per line, where its baseline lands (device px) when the text lays out from `originYPx`
    /// (device px, possibly fractional): rounded half up at its absolute place, as Skia rounds a
    /// text blob (`content.rs` #935: "its glyphs then round as Skia rounds them, the baseline half
    /// up"). The shaped baselines were rounded from a whole-pixel origin, so each line keeps its
    /// exact fraction (`ShapedText.lineBaselineFracsPx`) to round from here. Empty when the shaped
    /// text carries no baselines.
    public static func roundedBaselines(originYPx: Float, shaped: ShapedText) -> [Float] {
        let n = min(shaped.lineBaselinesPx.count, shaped.lineBaselineFracsPx.count)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = PixelSnap.roundHalfUp(originYPx + shaped.lineBaselinesPx[i] + shaped.lineBaselineFracsPx[i])
        }
        return out
    }

    /// A glyph quad's top (device px) on line `line`, `localTopPx` its top in the shaped text
    /// (device px from the layout's top): its baseline where `roundedBaselines` lands it, the glyph
    /// where it sits against its own baseline.
    @inline(__always)
    public static func glyphTop(localTopPx: Float, line: Int, roundedBaselines: [Float], shaped: ShapedText) -> Float {
        roundedBaselines[line] + (localTopPx - shaped.lineBaselinesPx[line])
    }
}

extension TextBoxGeometry {
    /// A pen at `at` device px rounded to a quarter pixel: the whole pixel its quad starts on and
    /// the quarter-pixel phase its mask is drawn at (`glyph_emit.rs`: `quarters = (at * 4).round();
    /// fx = (quarters / 4).floor(); phase = quarters - fx * 4`).
    @inline(__always)
    public static func quarterPen(_ at: Float) -> (fx: Float, phase: UInt8) {
        let quarters = (at * 4.0).rounded()
        let fx = (quarters / 4.0).rounded(.down)
        return (fx, UInt8(quarters - fx * 4.0))
    }
}

#if canImport(CoreText) && canImport(CoreGraphics)
/// A shaped glyph's face and exact pen (shaping px from the layout's left, its glide in), kept so
/// paint can round the pen at its absolute place (`glyph_emit.rs`, #935).
internal struct GlyphPen {
    let font: CTFont
    let glyph: CGGlyph
    let sizePx: Float
    let xPx: Float
    let binY: UInt8
    let smoothing: FontSmoothing
    let isColor: Bool
}

extension TextBoxGeometry {
    /// Glyph `g` (shaped at `shapeScale`) of a text laid out from `originXPx` (device px, possibly
    /// fractional): its pen rounds to a quarter pixel where it lands, its quad starts on that whole
    /// pixel and its mask is the one drawn at the leftover quarter (`glyph_emit.rs:286-288`). Colour
    /// glyphs round to a whole pixel. Returns the quad's left edge in device px and the glyph with
    /// its mask's `uv`, size and page.
    static func placedGlyph(
        _ g: PositionedGlyph,
        pen: GlyphPen,
        originXPx: Float,
        shapeScale s: Float,
        atlas: GlyphAtlas
    ) -> (xPx: Float, glyph: PositionedGlyph) {
        let at = originXPx + pen.xPx
        if pen.isColor {
            let bearing = g.rect.x * s - pen.xPx.rounded()
            return (at.rounded() + bearing, g)
        }
        let (fx, phase) = quarterPen(at)
        guard let entry = atlas.rasterizeGlyph(
            font: pen.font,
            glyph: pen.glyph,
            fontSizePx: pen.sizePx,
            subpixelX: Float(phase) * 0.25,
            subpixelYBin: pen.binY,
            smoothing: pen.smoothing
        ), entry.pixelSize.x > 0, entry.pixelSize.y > 0 else {
            return (originXPx + g.rect.x * s, g)
        }
        var out = g
        out.uv = entry.uv
        out.atlasPage = entry.page
        out.rect.z = Float(entry.pixelSize.x) / s
        out.rect.w = Float(entry.pixelSize.y) / s
        // `bearingPx.x` is `minX - phase / 4`: the quad starts on `fx + minX`, a whole pixel.
        return (fx + Float(phase) * 0.25 + entry.bearingPx.x, out)
    }
}
#endif

extension TextBoxGeometry {
    /// Glyph `index` of `shaped` (shaped at `pxScale`) for a text laid out from `originXPx` (device
    /// px): its quad's left edge in device px and the glyph to draw, its pen rounded to a quarter
    /// pixel where it lands (`placedGlyph`). Without its pens (a text that isn't CoreText-shaped) it
    /// keeps the shaped quad.
    static func restingGlyph(
        _ g: PositionedGlyph,
        index: Int,
        shaped: ShapedText,
        originXPx: Float,
        pxScale: Float,
        atlas: GlyphAtlas
    ) -> (xPx: Float, glyph: PositionedGlyph) {
        #if canImport(CoreText) && canImport(CoreGraphics)
        if shaped.glyphPens.count == shaped.glyphs.count, index >= 0, index < shaped.glyphPens.count {
            return placedGlyph(g, pen: shaped.glyphPens[index], originXPx: originXPx, shapeScale: pxScale, atlas: atlas)
        }
        #endif
        return (originXPx + g.rect.x * pxScale, g)
    }
}

/// Where a text's decorations land (device px `x, y, w, h`), from their shaped rects (points from
/// the text's top-left): upright at its own size each rounds to whole device pixels at its
/// absolute place, against its line's baseline as its glyphs round it (`decorations.rs:101-104`,
/// `:133-134`, #935), and a glide moves it after; scaled, it scales with the text.
struct TextDecorationPlacement {
    let shaped: ShapedText
    /// The text's origin as drawn (points), its glide in.
    let textOrigin: SIMD2<Float>
    let scale: SIMD2<Float>
    let pxScale: Float
    let roundedBaselines: [Float]
    let glideOffPx: SIMD2<Float>

    var onGrid: Bool { abs(scale.x - 1.0) < 1e-5 && abs(scale.y - 1.0) < 1e-5 }

    /// Where the text lays out from (device px): its drawn origin less its glide.
    var restOriginPx: SIMD2<Float> { textOrigin * pxScale - glideOffPx }

    /// How far (device px) line `yPt`'s baseline moved when it rounded where it lands.
    func baselineMove(centreYPt: Float) -> Float {
        let n = min(roundedBaselines.count, shaped.lineBaselinesPx.count)
        guard n > 0, shaped.lineHeight > 0 else { return 0 }
        // Its line by the shaped line tops, so lines inline code grew (#983) find theirs too.
        let line = min(n - 1, shaped.lineIndex(atLocalY: centreYPt, lineCount: n))
        return roundedBaselines[line] - (restOriginPx.y + shaped.lineBaselinesPx[line])
    }

    private func scaled(_ r: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(
            (textOrigin.x + r.x * scale.x) * pxScale,
            (textOrigin.y + r.y * scale.y) * pxScale,
            r.z * scale.x * pxScale,
            r.w * scale.y * pxScale
        )
    }

    /// A box whose four edges round where they land (span backgrounds, pill chips).
    func edges(_ r: SIMD4<Float>) -> SIMD4<Float> {
        guard onGrid else { return scaled(r) }
        let o = restOriginPx
        let dy = baselineMove(centreYPt: r.y + r.w * 0.5)
        let l = (o.x + r.x * pxScale).rounded(), rr = (o.x + (r.x + r.z) * pxScale).rounded()
        let t = (o.y + r.y * pxScale + dy).rounded(), b = (o.y + (r.y + r.w) * pxScale + dy).rounded()
        return SIMD4<Float>(l + glideOffPx.x, t + glideOffPx.y, rr - l, b - t)
    }

    /// A box that keeps its size and rounds its top-left where it lands (icons, images).
    func origin(_ r: SIMD4<Float>) -> SIMD4<Float> {
        guard onGrid else { return scaled(r) }
        let o = restOriginPx
        let dy = baselineMove(centreYPt: r.y + r.w * 0.5)
        return SIMD4<Float>(
            (o.x + r.x * pxScale).rounded() + glideOffPx.x,
            (o.y + r.y * pxScale + dy).rounded() + glideOffPx.y,
            r.z * pxScale,
            r.w * pxScale
        )
    }

    /// A horizontal line (strikethrough): its ends and top round where they land, its thickness kept.
    func line(_ r: SIMD4<Float>) -> SIMD4<Float> {
        guard onGrid else { return scaled(r) }
        let o = restOriginPx
        let dy = baselineMove(centreYPt: r.y)
        let l = (o.x + r.x * pxScale).rounded(), rr = (o.x + (r.x + r.z) * pxScale).rounded()
        return SIMD4<Float>(l + glideOffPx.x, (o.y + r.y * pxScale + dy).rounded() + glideOffPx.y, rr - l, r.w * pxScale)
    }

    /// An underline: its edges from `underline_edges` (always, `decorations.rs:134`), its top
    /// rounded where it lands upright at its own size, its thickness kept.
    func underline(_ u: SIMD4<Float>, lineEndPt: Float?) -> SIMD4<Float> {
        var r = line(u)
        let k = scale.x * pxScale
        let ox = onGrid ? restOriginPx.x : textOrigin.x * pxScale
        let end = lineEndPt ?? (u.x + u.z)
        let (l, rr) = TextDecorations.underlineEdges(lineEndPx: end * k, originX: ox, startX: u.x * k, endX: (u.x + u.z) * k)
        let gx: Float = onGrid ? glideOffPx.x : 0
        r.x = l + gx
        r.z = rr - l
        return r
    }
}

extension PixelSnap.Parent {
    /// How far its exact resting top-left sits from where it rests snapped (device px), `rigid`
    /// as it was snapped with: where a text inside lays out from, at rest and through a glide
    /// alike (`pixel_snap::Parent::exact_off`, #935).
    public func exactOff(rigid: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(
            rest.exact[0] + rigid[0] - rest.at[0] - PixelSnap.roundHalfUp(rigid[0]),
            rest.exact[1] + rigid[1] - rest.at[1] - PixelSnap.roundHalfUp(rigid[1])
        )
    }
}
