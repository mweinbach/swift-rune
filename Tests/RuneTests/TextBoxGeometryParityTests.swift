import Foundation
import Testing
@testable import Rune
#if canImport(CoreGraphics) && canImport(CoreText)
import CoreText
#endif

/// Text box geometry: 64th-of-a-pixel widths (#934), fit slack (#948), the exact resting origin
/// (#935) and text under an offset / underline edges (#963).
@Suite("Text box geometry (text_layout.rs text_width/FIT_SLACK, LeafBox::exact_off, pixel_rect, underline_edges)")
struct TextBoxGeometryParityTests {
    private func whole(_ v: Float) -> Bool { v.truncatingRemainder(dividingBy: 1.0) == 0.0 }

    private func fills(_ scene: RefScene) -> [SIMD4<Float>] {
        scene.primitives.compactMap { p in
            p.params.y == Float(PrimitiveKind.roundedRect.rawValue) && p.fill.w > 0 ? p.rect : nil
        }
    }

    private struct SceneProxy { let primitives: [Primitive]; init(_ p: [Primitive]) { primitives = p } }

    private func fills(_ scene: SceneProxy) -> [SIMD4<Float>] {
        scene.primitives.compactMap { p in
            p.params.y == Float(PrimitiveKind.roundedRect.rawValue) && p.fill.w > 0 ? p.rect : nil
        }
    }

    private func glyphTop(_ scene: RefScene) -> Float {
        scene.primitives
            .filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
            .map { $0.rect.y }
            .min() ?? .greatestFiniteMagnitude
    }

    // MARK: - #934 text_width

    @Test("text_width rounds device px up to a 64th, within 1e-3 of the run's own width")
    func textWidthRoundsUpToA64th() {
        #expect(TextBoxGeometry.textWidth(10.0) == 10.0)
        // Within 1e-3 px above a 64th it stays on that 64th.
        #expect(TextBoxGeometry.textWidth(10.0005) == 10.0)
        #expect(TextBoxGeometry.textWidth(10.002) == 10.0 + 1.0 / 64.0)
        #expect(TextBoxGeometry.textWidth(50.79) == 3251.0 / 64.0)
        #expect(TextBoxGeometry.textWidth(0.0) == 0.0)
        #expect(TextBoxGeometry.textWidth(0.0005) == 0.0)
        #expect(TextBoxGeometry.textWidth(-3.0) == 0.0)
        // Not a whole pixel, as it was: 50.797 px no longer becomes 51.
        #expect(TextBoxGeometry.textWidth(50.797) < 51.0)
        // Idempotent: a width already on a 64th keeps it.
        for k in 0..<256 {
            let w = Float(k) / 64.0 + 3.0
            #expect(TextBoxGeometry.textWidth(w) == w)
        }
    }

    @Test("a text box is as wide as its widest line to a 64th of a device pixel (compute_layout lw, #934)")
    func textBoxIsAsWideAsItsTextToA64th() throws {
        for scale: Float in [1.0, 1.25, 1.875, 2.0] {
            let ts = TextSystem()
            let style = TextStyle(size: 13, weight: 400)
            let shaped = ts.shape(text: "New tab", style: style, maxWidth: nil, pixelScale: scale, emitGlyphs: false)
            let raw = try #require(shaped.lineAdvancesPx.first).widthPx
            let want = TextBoxGeometry.textWidth(raw) / scale
            #expect(shaped.size.x == want, "scale \(scale): \(shaped.size.x) vs \(want)")
            #expect(shaped.size.x * scale >= raw - 1e-3 && shaped.size.x * scale < raw + 1.0 / 64.0)

            let rt = Runtime(state: (), viewport: Vec2(200, 40), pixelScale: scale) { _, _ in
                row().child(text("New tab").font(style).key("t"))
            }
            _ = rt.frame(at: 0.0)
            let w = try #require(rt.element(byKey: "t")).rect[2]
            #expect(abs(w - want) < 1e-4, "scale \(scale): laid out \(w) vs \(want)")
            let w64 = w * scale * 64.0
            #expect(abs(w64 - w64.rounded()) < 1e-2, "scale \(scale): \(w) pt is a 64th of a device px")
        }
    }

    @Test("text::measure_with rounds widths up to a 64th of a point (#934)")
    func measureWithRoundsToA64th() {
        let style = TextStyle(size: 14, weight: 400)
        for t in ["draft cursor, updatedAt", "New tab", "Copy password"] {
            let w = TextMeasure.measure(t, style: style).x
            let w64 = w * 64.0
            #expect(w64 == w64.rounded(), "\(t): \(w)")
        }
    }

    @Test("a run ends at its width in 64ths of a pixel, as a text box does (run.rs, #934)")
    func runLayoutEndsAtTextWidth() throws {
        let ts = TextSystem()
        let style = TextStyle(size: 13, weight: 400)
        let run = ts.runLayout(TextRun("Copy password"), style: style, scale: 2.0)
        let end = try #require(run.graphemes.last).xPx
        let box = ts.shape(text: "Copy password", style: style, maxWidth: nil, pixelScale: 2.0, emitGlyphs: false).size.x * 2.0
        #expect(end == box)
        #expect(run.totalWidthPx == box)
        #expect(end * 64.0 == (end * 64.0).rounded())
    }

    /// `TextSystem::measure` / `compute_layout` (#934) on the portable (headless) shaper, the one
    /// Linux, Windows, Android and the web build: its box is `text_width(w * scale) / scale`, the
    /// rounding factored into `TextBoxGeometry.boxWidth` so it is built and tested here too.
    @Test("the portable shaper sizes a box to its widest line to a 64th of a device pixel (#934)")
    func portableShaperBoxWidthIsA64th() {
        // The rounding itself: `text_width(w * scale) / scale`.
        #expect(TextBoxGeometry.boxWidth(maxLineWidthPt: 50.797, scale: 1.0) == 3251.0 / 64.0)
        #expect(TextBoxGeometry.boxWidth(maxLineWidthPt: 0.0, scale: 2.0) == 0.0)
        #expect(TextBoxGeometry.boxWidth(maxLineWidthPt: 10.0, scale: 2.0) == 10.0)
        #expect(TextBoxGeometry.boxWidth(maxLineWidthPt: 10.0004, scale: 2.0) == 10.0)
        #expect(TextBoxGeometry.boxWidth(maxLineWidthPt: 10.001, scale: 2.0) == 10.0 + 1.0 / 128.0)
        for scale: Float in [1.0, 1.25, 1.5, 1.875, 2.0] {
            for k in 0..<40 {
                let w = 20.0 + Float(k) * 0.37
                let box = TextBoxGeometry.boxWidth(maxLineWidthPt: w, scale: scale)
                #expect(box == TextBoxGeometry.textWidth(w * scale) / scale)
                #expect(box * scale >= w * scale - 1e-3 && box * scale < w * scale + 1.0 / 64.0)
            }
        }

        // The portable shaper and its measure size their boxes with it.
        let ts = TextSystem()
        let style = TextStyle(size: 13, weight: 400)
        for scale: Float in [1.0, 1.25, 1.875, 2.0] {
            for label in ["New tab", "Copy password", "AVATAR Tokyo, WAVE", "draft cursor, updatedAt"] {
                let line = label.reduce(Float(0)) { acc, ch in
                    acc + ch.unicodeScalars.reduce(Float(0)) { $0 + PortableGlyphFont.advanceRatio(for: $1, mono: false) * style.size }
                }
                let shaped = ts.shapePortable(text: label, style: style, maxWidth: nil, pixelScale: scale, emitGlyphs: false)
                let want = TextBoxGeometry.boxWidth(maxLineWidthPt: line, scale: scale)
                #expect(abs(shaped.size.x - want) < 1e-4, "\(label) at \(scale): \(shaped.size.x) vs \(want)")
                let px64 = shaped.size.x * scale * 64.0
                #expect(abs(px64 - px64.rounded()) < 1e-2, "\(label) at \(scale): \(shaped.size.x) pt is a 64th of a device px")
                let measured = ts.measurePortable(label, style: style, maxWidth: nil, pixelScale: scale, bypassCache: true)
                #expect(measured.x == shaped.size.x)
            }
        }
    }

    // MARK: - #948 FIT_SLACK

    @Test("FIT_SLACK is 1/256 device px, added to the wrap width (w * scale + FIT_SLACK)")
    func fitSlackWidensTheWrapWidth() {
        #expect(TextBoxGeometry.fitSlack == 1.0 / 256.0)
        #expect(TextBoxGeometry.wrapWidth(nil, scale: 2.0) == nil)
        let w = TextBoxGeometry.wrapWidth(100.0, scale: 2.0)!
        #expect(abs(w * 2.0 - (200.0 + 1.0 / 256.0)) < 1e-5)
        let w1 = TextBoxGeometry.wrapWidth(37.5, scale: 1.25)!
        #expect(abs(w1 * 1.25 - (37.5 * 1.25 + 1.0 / 256.0)) < 1e-5)
    }

    @Test("a text laid out again in its own shrink-to-fit box keeps its lines (#948)")
    func textLaidOutAgainInItsOwnBoxFits() throws {
        let labels = ["New tab", "Copy password", "AVATAR Tokyo, WAVE", "draft cursor, updatedAt", "Quiet harbor glides"]
        for scale: Float in [1.0, 1.25, 1.5, 1.875, 2.0] {
            for label in labels {
                let style = TextStyle(size: 13, weight: 400)
                let rt = Runtime(state: (), viewport: Vec2(400, 80), pixelScale: scale) { _, _ in
                    El<()>().size(400, 80).child(
                        El<()>().absolute(x: 3.3, y: 2.0).child(text(label).font(style).wrap(.wrap).key("t"))
                    )
                }
                _ = rt.frame(at: 0.0)
                let r = try #require(rt.element(byKey: "t")).rect
                let oneLine = TextSystem.specLineHeight(lineCount: 1, lineHeightPt: style.resolvedLineHeight, scale: scale, exact: style.exactLines)
                #expect(abs(r[3] - oneLine) < 1e-3, "\(label) at \(scale): \(r[3]) pt tall, one line is \(oneLine)")
            }
        }
    }

    // MARK: - #935 exact_off / pixel_rect

    @Test("Parent::exact_off is the exact resting edge against the snapped one, rigid as it snapped")
    func parentExactOff() {
        let rest = PixelSnap.Rest(exact: SIMD4<Float>(10.3, 20.6, 50.3, 40.6), at: SIMD4<Float>(10, 21, 50, 41))
        let p = PixelSnap.Parent(rest: rest, now: rest, left: .zero)
        let o = p.exactOff(rigid: SIMD2<Float>(0.4, 0.0))
        #expect(abs(o.x - 0.7) < 1e-5 && abs(o.y - -0.4) < 1e-5)
        // A rigid translation that rounds up carries its whole pixel in the snapped place.
        let o2 = p.exactOff(rigid: SIMD2<Float>(0.6, 1.5))
        #expect(abs(o2.x - (10.3 + 0.6 - 10 - 1)) < 1e-5 && abs(o2.y - (20.6 + 1.5 - 21 - 2)) < 1e-5)

        // Snapped where it rests: exact - snapped (edges on 64ths of a device px, as `snap_px` gives them).
        let r = SIMD4<Float>(20.625, 9.3125, 60.1875, 31.6875)
        let (out, snapRest) = PixelSnap.snap(r, motion: .zero, rigid: .zero, parent: nil) { _, c in c }
        let off = PixelSnap.Parent(rest: snapRest, now: snapRest, left: .zero).exactOff(rigid: .zero)
        #expect(abs(off.x - (r[0] - out[0])) < 1e-4 && abs(off.y - (r[1] - out[1])) < 1e-4)
    }

    @Test("LeafBox::exact_off adds its containment's rounding and is zero under an offset (#935, #963)")
    func leafExactOffContainsAndShifts() {
        let rest = PixelSnap.Rest(exact: SIMD4<Float>(10.3, 20.6, 50.3, 40.6), at: SIMD4<Float>(10, 21, 50, 41))
        let p = PixelSnap.Parent(rest: rest, now: rest, left: .zero)
        let c = SIMD2<Float>(3.3, 2.6)
        let o = TextBoxGeometry.leafExactOff(rest: p, rigid: .zero, containPx: c, shifted: false)
        #expect(abs(o.x - (0.3 + 3.0 - 3.3)) < 1e-5 && abs(o.y - (-0.4 + 3.0 - 2.6)) < 1e-5)
        #expect(TextBoxGeometry.leafExactOff(rest: p, rigid: .zero, containPx: c, shifted: true) == .zero)
        // Without a resting place only the containment's rounding is left.
        let bare = TextBoxGeometry.leafExactOff(rest: nil, rigid: .zero, containPx: c, shifted: false)
        #expect(abs(bare.x - -0.3) < 1e-5 && abs(bare.y - 0.4) < 1e-5)
        #expect(TextBoxGeometry.leafExactOff(rest: nil, rigid: .zero, containPx: .zero, shifted: false) == .zero)
    }

    @Test("only a still, unscaled text that isn't a field lays out from its exact place")
    func restsExactGate() {
        #expect(TextBoxGeometry.restsExact(isInput: false, scaleStill: true, scale: SIMD2<Float>(1, 1)))
        #expect(!TextBoxGeometry.restsExact(isInput: true, scaleStill: true, scale: SIMD2<Float>(1, 1)))
        #expect(!TextBoxGeometry.restsExact(isInput: false, scaleStill: false, scale: SIMD2<Float>(1, 1)))
        #expect(!TextBoxGeometry.restsExact(isInput: false, scaleStill: true, scale: SIMD2<Float>(1.2, 1.2)))
    }

    @Test("text_marks::pixel_rect rounds a highlight's edges to whole device pixels")
    func pixelRectRoundsEdges() {
        let r = TextBoxGeometry.pixelRect(
            origin: SIMD2<Float>(10.3, 4.15),
            box: SIMD4<Float>(2.1, 0.0, 30.45, 16.25),
            k: SIMD2<Float>(1, 1),
            pxScale: 2.0
        )
        // x0 = round(24.8) = 25, x1 = round(85.7) = 86; y0 = round(8.3) = 8, y1 = round(40.8) = 41.
        #expect(r == SIMD4<Float>(25, 8, 61, 33))
        let k = TextBoxGeometry.pixelRect(origin: SIMD2<Float>(0, 0), box: SIMD4<Float>(1, 1, 2, 2), k: SIMD2<Float>(1.5, 1.5), pxScale: 1.25)
        // 1.875 -> 2, 5.625 -> 6.
        #expect(k == SIMD4<Float>(2, 2, 4, 4))
    }

    @Test("baselines round half up where they land, from a fractional origin (Skia's text blob)")
    func baselinesRoundWhereTheyLand() throws {
        let ts = TextSystem()
        let shaped = ts.shape(text: "Hg\nHg", style: TextStyle(size: 13, weight: 400), maxWidth: nil, pixelScale: 2.0, emitGlyphs: true)
        // Inter at 26 device px has a quantized ascent of 25 px. Parley rounds the second
        // line's 32.5 px top to 33 before adding that ascent.
        try #require(shaped.lineBaselinesPx == [25, 58])
        for k in 0..<64 {
            let o = 20.0 + Float(k) / 64.0
            let at = TextBoxGeometry.roundedBaselines(originYPx: o, shaped: shaped)
            for i in 0..<2 {
                let exact = o + shaped.lineBaselinesPx[i]
                #expect(at[i] == (exact + 0.5).rounded(.down))
            }
        }
    }

    // MARK: - Runtime: exact origin and offsets

    @Test("a text under an offset moves with its box, as before #935 (#963)")
    func textUnderAnOffsetMovesWithItsBox() {
        func offset(y: Float) -> (Float, Float) {
            let rt = Runtime(state: y, viewport: Vec2(80, 40), pixelScale: 2.0) { y, _ in
                let label: El<Float> = text("Hg")
                return El<Float>().size(80, 40).child(
                    label.p(2.3).absolute(x: 4.0, y: 10.0).offset(0, y - 10.0)
                        .bg(Color.white.mix(with: .black, t: 0.8))
                )
            }
            let sc = rt.frame(at: 0.0)
            let fill = fills(sc)[0]
            let top = glyphTop(sc)
            #expect(top < .greatestFiniteMagnitude, "draws glyphs")
            return (top - fill.y, fill.y)
        }
        let (want, _) = offset(y: 10.05)
        for k in 2..<10 {
            let (got, top) = offset(y: 10.0 + Float(k) * 0.05)
            #expect(whole(top))
            #expect(abs(got - want) < 1e-3, "keeps its place against its fill under an offset: \(got) vs \(want)")
        }
    }

    #if canImport(CoreGraphics) && canImport(CoreText)
    @Test("hinted Latin and small CJK share a phase-zero mask and move its bearing at half a pixel")
    func wholePenMasksAndBearings() throws {
        let latin = CTFontCreateWithName("HelveticaNeue" as CFString, 13, nil)
        let cjk = CTFontCreateForString(latin, "水" as CFString, CFRange(location: 0, length: 1))
        func entries(_ font: CTFont, character: UniChar, mode: FontSmoothing) throws -> [GlyphAtlas.Entry] {
            var ch = character
            var glyph = CGGlyph()
            try #require(CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1))
            let atlas = GlyphAtlas(width: 128, height: 128)
            return try [UInt8(0), 15, 30, 45].map { phase in
                try #require(atlas.rasterizeGlyph(font: font, glyph: glyph, fontSizePx: Float(CTFontGetSize(font)),
                                                   phaseX: phase, smoothing: mode))
            }
        }
        for set in [try entries(latin, character: 0x48, mode: .hinted),
                    try entries(cjk, character: 0x6c34, mode: .windfoilChromium)] {
            #expect(set.allSatisfy { $0.pixelOrigin == set[0].pixelOrigin && $0.page == set[0].page })
            #expect(set.map(\.bearingPx.x) == [0, 0, 1, 1].map { set[0].bearingPx.x + $0 })
        }
        for set in [try entries(latin, character: 0x48, mode: .hintedGpu),
                    try entries(cjk, character: 0x6c34, mode: .hintedGpu),
                    try entries(CTFontCreateCopyWithAttributes(cjk, 25, nil, nil), character: 0x6c34, mode: .windfoilChromium)] {
            #expect(Set(set.map(\.pixelOrigin)).count == 4)
        }
    }

    @Test("CoreGraphics pens quantize by size before a glide moves them")
    func glyphPlacementUsesNativePhases() {
        let edge = TextBoxGeometry.glyphPen(at: 8.49, ppem: 26, glide: 0, smoothing: .on)
        #expect(edge.pixel == 8 && edge.phase == 0)
        let small = TextBoxGeometry.glyphPen(at: 8.74, ppem: 13, glide: 0, smoothing: .off)
        #expect(small.pixel == 8 && small.phase == 40)
        let glide = TextBoxGeometry.glyphPen(at: 8.74, ppem: 13, glide: 0.5, smoothing: .off)
        #expect(glide.pixel == 9 && glide.phase == 10)
        let skia = TextBoxGeometry.glyphPen(at: 8.49, ppem: 26, glide: 0, smoothing: .windfoil)
        #expect(skia.pixel == 8 && skia.phase == 30)
    }
    #endif

    @Test("quarterPen rounds a pen to a quarter pixel: its whole pixel and its phase (glyph_emit.rs)")
    func quarterPenRoundsToAQuarter() {
        #expect(TextBoxGeometry.quarterPen(6.59375) == (6.0, 2))
        #expect(TextBoxGeometry.quarterPen(6.0) == (6.0, 0))
        #expect(TextBoxGeometry.quarterPen(6.9) == (7.0, 0))
        #expect(TextBoxGeometry.quarterPen(3.3125) == (3.0, 1))
        #expect(TextBoxGeometry.quarterPen(3.125) == (3.0, 1))
        #expect(TextBoxGeometry.quarterPen(-0.3) == (-1.0, 3))
        #expect(TextBoxGeometry.quarterPen(-0.125) == (0, 0))
        #expect(TextBoxGeometry.quarterPen(329.37353515625) == (329, 2))
    }

    /// A text laid out from a fractional exact place: every glyph quad starts on a whole device
    /// pixel (its pen rounds to a quarter where it lands, the leftover quarter in its mask's phase,
    /// `glyph_emit.rs:286-288`), and its glyph rows sit on whole pixels (`content.rs`, #935).
    @Test("glyph quads start on whole device pixels from a fractional exact origin, X and Y")
    func exactPlaceGlyphQuadsStayWhole() {
        for scale: Float in [1.0, 1.25, 1.5, 1.875, 2.0] {
            for k in 0..<8 {
                let x = 3.3 + Float(k) * 0.13
                let y = 5.0 + Float(k) * 0.17
                let rt = Runtime(state: SIMD2<Float>(x, y), viewport: Vec2(160, 40), pixelScale: scale) { at, _ in
                    El<SIMD2<Float>>().size(160, 40).child(text("Hg Quiet harbor").p(1.1).absolute(x: at.x, y: at.y))
                }
                let quads = rt.frame(at: 0.0).primitives.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
                #expect(quads.count >= 10, "scale \(scale): draws glyphs")
                let gpuQuads = rt.renderFrame(at: 0).instances.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
                #expect(gpuQuads.map(\.rect) == quads.map(\.rect))
                for q in quads {
                    #expect(abs(q.rect.x - q.rect.x.rounded()) < 1e-3, "scale \(scale) at \(x): glyph quad x \(q.rect.x)")
                    #expect(abs(q.rect.y - q.rect.y.rounded()) < 1e-3, "scale \(scale) at \(y): glyph quad y \(q.rect.y)")
                }
            }
        }
    }

    @Test("a text's ink moves a device pixel per device pixel of travel, never back (X, #935)")
    func exactPlaceInkTracksItsBoxAcross() {
        func left(_ x: Float) -> Float {
            let rt = Runtime(state: x, viewport: Vec2(120, 40), pixelScale: 2.0) { x, _ in
                El<Float>().size(120, 40).child(text("Hg").absolute(x: x, y: 4.0))
            }
            return rt.frame(at: 0.0).primitives
                .filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
                .map { $0.rect.x }
                .min() ?? .greatestFiniteMagnitude
        }
        for k in 0..<10 {
            let x = 10.0 + Float(k) * 0.05
            let (a, next, lower) = (left(x), left(x + 0.05), left(x + 0.5))
            #expect(lower == a + 1.0, "x \(x): a device pixel right draws a pixel right")
            #expect(next == a || next == a + 1.0, "x \(x): \(a) then \(next)")
        }
    }

    /// Span backgrounds and underlines round where they land, against the baseline the glyphs round
    /// to (`decorations.rs:101-104`, `:133`, #935).
    @Test("decorations round to whole device pixels where they land, with the glyph baselines")
    func decorationsRoundWithTheBaselines() {
        let bg = Color(r: 0.1, g: 0.6, b: 0.3, a: 1)
        for scale: Float in [1.25, 2.0] {
            var underToGlyph: Set<Float> = []
            for k in 0..<8 {
                let at = SIMD2<Float>(3.3 + Float(k) * 0.13, 5.0 + Float(k) * 0.17)
                let rt = Runtime(state: at, viewport: Vec2(200, 40), pixelScale: scale) { at, _ in
                    El<SIMD2<Float>>().size(200, 40).child(
                        rich([TextSpan("Hg ", background: bg), TextSpan("under", underline: true)]).absolute(x: at.x, y: at.y)
                    )
                }
                let prims = rt.frame(at: 0.0).primitives
                let rects = prims.filter { $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && $0.fill.w > 0 }
                let glyphTop = prims.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }.map { $0.rect.y }.min() ?? 0
                #expect(rects.count >= 2, "scale \(scale): background and underline")
                for r in rects {
                    #expect(whole(r.rect.x) && whole(r.rect.y) && whole(r.rect.x + r.rect.z), "scale \(scale) at \(at): \(r.rect)")
                }
                // The underline is the thin one; the background is a line tall.
                if let under = rects.min(by: { $0.rect.w < $1.rect.w }) {
                    underToGlyph.insert(under.rect.y - glyphTop)
                }
            }
            // The underline keeps its place against the glyphs at every phase.
            #expect(underToGlyph.count == 1, "scale \(scale): \(underToGlyph)")
        }
    }

    /// `relayout::lay_out_text` lays every wrapping text out again at its layout width plus
    /// FIT_SLACK, never its snapped width: a gliding label (which paint shapes again each frame) in a
    /// shrink-to-fit box whose snapped fill is more than half a point under its exact width keeps its
    /// words on one line (#948).
    @Test("a gliding wrapping text lays out again at its layout width, not its snapped one (#948)")
    func glidingTextLaysOutAgainAtItsLayoutWidth() throws {
        struct Glide: Sendable { var label: String; var x: Float; var dy: Float }
        var narrowSnaps = 0
        for label in ["Copy password now", "New tab here", "AVATAR Tokyo, WAVE", "Quiet harbor glides", "draft cursor, updatedAt"] {
            for k in 0..<20 {
                let x = Float(k) * 0.05
                let rt = Runtime(state: Glide(label: label, x: x, dy: 0), viewport: Vec2(300, 80), pixelScale: 1.0) { s, _ in
                    El<Glide>().size(300, 80).child(
                        text(s.label).wrap(.wrap).absolute(x: s.x, y: 4.0).offset(0, s.dy)
                            .animate(Spring(duration: 0.4, bounce: 0)).bg(.white).key("t")
                    )
                }
                var t = 0.0
                _ = rt.frame(at: t)
                let exact = try #require(rt.element(byKey: "t")).rect[2]
                rt.update(at: t) { st, _ in st.dy = 7.3 }
                for _ in 0..<12 {
                    t += 1.0 / 60.0
                    let prims = rt.frame(at: t).primitives
                    if let fill = fills(SceneProxy(prims)).first, exact - fill.z > 0.5 {
                        narrowSnaps += 1
                    }
                    let ys = prims
                        .filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
                        .map { $0.rect.y + $0.rect.w }
                    guard let lo = ys.min(), let hi = ys.max() else { continue }
                    // One line: every glyph's bottom sits within a few device px (descenders) of the others.
                    #expect(hi - lo < 8.0, "\(label) at x \(x): glyph bottoms span \(lo)...\(hi), the text wrapped")
                }
            }
        }
        // The case #948 is about came up: a box snapped more than half a point under its text.
        #expect(narrowSnaps > 0)
    }

    /// `relayout::lay_out_text` wraps a text at `w * scale + FIT_SLACK` device px (#948), and paint
    /// and selection hit-testing lay it out again at that same width: a text a third of a point
    /// wider than its box wraps its last word in layout, so it wraps on screen and under the
    /// pointer too (it ran on at `w + 0.5` pt before, one line drawn over a two-line box).
    @Test("paint and selection hit-testing wrap where layout does, at w * scale + FIT_SLACK, not w + 0.5 pt (#948)")
    func paintAndHitTestingWrapAtTheLayoutWidth() throws {
        let label = "Quiet harbor"
        let style = TextStyle(size: 13, weight: 400)
        for scale: Float in [1.0, 1.25, 2.0] {
            let natural = TextSystem().shape(text: label, style: style, maxWidth: nil, pixelScale: scale, emitGlyphs: false).size.x
            let w = natural - 0.3
            let rt = Runtime(state: w, viewport: Vec2(300, 80), pixelScale: scale) { w, _ in
                El<Float>().size(300, 80).child(
                    text(label).font(style).wrap(.wrap).w(w).absolute(x: 4.0, y: 4.0).selectable().key("t")
                )
            }
            let prims = rt.frame(at: 0.0).primitives
            let e = try #require(rt.element(byKey: "t"))
            let lh = style.resolvedLineHeight
            let twoLines = TextSystem.specLineHeight(lineCount: 2, lineHeightPt: lh, scale: scale, exact: style.exactLines)
            #expect(abs(e.rect[3] - twoLines) < 1e-3, "scale \(scale): layout wraps \(label) at \(w) pt (\(e.rect[3]) pt tall)")

            // Paint: two rows of glyphs.
            let bottoms = prims
                .filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
                .map { $0.rect.y + $0.rect.w }
            let lo = try #require(bottoms.min()), hi = try #require(bottoms.max())
            #expect(hi - lo > lh * scale * 0.6, "scale \(scale): paint wraps too (glyph bottoms \(lo)...\(hi))")

            // Hit-testing: just inside the second line's start is the start of its word.
            let node = try #require(rt.flatNodes.first { $0.key == "t" })
            let at = Vec2(4.0 + 0.5, 4.0 + lh * 1.5)
            #expect(rt.selectableHitOffset(node: node, windowPos: at) == "Quiet ".utf8.count, "scale \(scale): hit-testing wraps too")
        }
    }

    @Test("a clamped text laid out again in its own box isn't elided (FIT_SLACK in paint, #948)")
    func clampedTextLaidOutAgainFits() throws {
        let labels = ["New tab", "Copy password", "AVATAR Tokyo, WAVE", "draft cursor, updatedAt"]
        for scale: Float in [1.0, 1.25, 1.5, 1.875, 2.0] {
            for label in labels {
                let rt = Runtime(state: (), viewport: Vec2(400, 80), pixelScale: scale) { _, _ in
                    El<()>().size(400, 80).child(
                        El<()>().absolute(x: 3.3, y: 2.0).child(text(label).maxLines(1).key("t"))
                    )
                }
                _ = rt.frame(at: 0.0)
                let e = try #require(rt.element(byKey: "t"))
                #expect(e.elision == nil, "\(label) at \(scale): elided to \(e.drawnText ?? "")")
            }
        }
    }

    // MARK: - #963 underline_edges

    @Test("underline_edges: a run that ends its line ends where it ends, not its width rounded up")
    func underlineEdgesEndAtTheRunsEnd() {
        // Ends its line at 79.3 px: it ends at round(10 + 79.3) = 89, not ceil(79.3) + 10 = 90.
        let e = TextDecorations.underlineEdges(lineEndPx: 79.3, originX: 10.0, startX: 0.4, endX: 79.3)
        #expect(e.0 == 10.0 && e.1 == 89.0)
        // A run inside its line rounds its end in layout space first.
        let mid = TextDecorations.underlineEdges(lineEndPx: 120.0, originX: 10.3, startX: 20.6, endX: 49.4)
        #expect(mid.0 == 31.0 && mid.1 == 59.0)
        // The next box starts where this one's text ends rounded alike.
        let next = TextBoxGeometry.textWidth(79.3)
        #expect((10.0 + next).rounded() == e.1)
    }

    /// `quality_tests.rs` `underlined_words_in_a_row_meet_without_gaps` (t942, #963): a link flowed a
    /// word an element underlines as one line: each word's line meets the next one's at the space,
    /// with no gap or overlap where an element's width rounds up.
    @Test("underlined_words_in_a_row_meet_without_gaps")
    func underlinedWordsInARowMeetWithoutGaps() {
        let words = ["Watch ", "Kaizen ", "× ", "OpenCode ", "(4:12, ", "1080p60) ", "→"]
        let rt = Runtime(state: words, viewport: Vec2(600, 100), pixelScale: 2.0) { s, _ in
            row().children(s.map { w in rich([TextSpan(w, underline: true)]) })
        }
        let sc = rt.frame(at: 0.0)
        var lines: [(Float, Float)] = sc.primitives
            .filter { $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && $0.rect.w == 2.0 }
            .map { ($0.rect.x, $0.rect.x + $0.rect.z) }
        lines.sort { $0.0 < $1.0 }
        #expect(lines.count == 7, "\(lines)")
        for i in 1..<max(1, lines.count) {
            #expect(lines[i - 1].1 == lines[i].0, "each line meets the next: \(lines)")
        }
    }
}
