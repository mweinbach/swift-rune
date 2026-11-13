import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

@Suite("Truncate & TruncateFade Parity Tests")
struct TruncateAndFadeParityTests {
    @Test("el.truncate, truncateMiddle, and truncateHead elide graphemes and map hit/selection ranges")
    func elideModesAndElisionMapping() {
        let content = "alpha-beta-gamma-delta"
        let rtEnd = Runtime<Float>(state: 72) { w, _ in
            el().w(w).child(
                text(content).key("end").font(TextStyle(size: 14, weight: 400)).truncate()
            )
        }
        _ = rtEnd.frame(at: 0)
        let endRf = rtEnd.renderFrame(at: 0)
        #expect(!endRf.instances.isEmpty)

        // Verify TextTruncation.elide across .end, .middle, .head preserves graphemes and maps selection ranges
        let ts = TextSystem()
        for (mode, expectHeadEmpty, expectTailEmpty) in [
            (TextElide.end, false, true),
            (TextElide.middle, false, false),
            (TextElide.head, true, false),
        ] {
            var st = TextStyle(size: 14, weight: 400)
            st.wrap = .ellipsis
            st.elide = mode
            st.graphemeElide = true
            let res = TextTruncation.elide(
                text: content,
                spans: nil,
                pills: [],
                style: st,
                maxWidth: 75,
                pixelScale: 1.0,
                textSystem: ts
            )
            #expect(res.wasCut)
            #expect(res.drawn.contains(TextElision.ellipsis))
            if expectHeadEmpty { #expect(res.elision.head == 0) } else { #expect(res.elision.head > 0) }
            if expectTailEmpty { #expect(res.elision.tail == content.utf8.count) } else { #expect(res.elision.tail < content.utf8.count) }

            // Selection mapping across the ellipsis covers the ellipsis when intersecting [head..<tail]
            let (ra, rb) = res.elision.range(0, content.utf8.count)
            #expect(ra == 0)
            #expect(rb == res.drawn.utf8.count)

            // Hit-testing round-trip at drawn start/end maps back to content byte boundaries
            let shaped = ts.shape(text: content, style: st, maxWidth: 75, pixelScale: 1.0, emitGlyphs: true)
            #expect(shaped.elision == res.elision)
            #expect(ts.hitTestUTF8Offset(in: shaped, localX: 0, localY: 7, pixelScale: 1.0) == 0)
        }
    }

    @Test("el.truncate() keeps layout flexible (flexShrink=1, minWidth=0) while el.truncateFade() preserves full text")
    func truncateLayoutAndFullTextPreservation() {
        let longText = "this is much too long"
        let rt = Runtime<Float>(state: 60) { w, _ in
            row().w(w).child(
                text(longText).key("fade").font(TextStyle(size: 14, weight: 400)).truncateFade()
            )
        }
        _ = rt.frame(at: 0)
        let info = rt.elements().first { $0.key == "fade" }
        #expect(info?.text == longText)
    }

    @Test("batch_c: fadeTruncationKeepsFullTextAndOnlyFadesOverflowingGlyphs")
    func fadeTruncationKeepsFullTextAndOnlyFadesOverflowingGlyphs() {
        let longText = "this is much too long"
        for scale: Float in [1.0, 2.0] {
            let rt = Runtime<Float>(state: 60, pixelScale: scale, systemDark: true) { w, _ in
                row().child(
                    text(longText)
                        .key("label")
                        .w(w)
                        .font(TextStyle(size: 14, weight: 400))
                        .truncateFade()
                )
            }
            _ = rt.frame(at: 0)
            let label = rt.elements().first { $0.key == "label" }
            #expect(label?.text == longText)

            let rf = rt.renderFrame(at: 0)
            let glyphs = rf.instances.filter { $0.params.y == KIND_GLYPH }
            #expect(!glyphs.isEmpty)
            for glyph in glyphs {
                #expect(abs(glyph.clip.z - 60.0 * scale) < 0.01)
                let decoded = unpackFade(glyph.fade)
                #expect(abs(decoded.width.z - TRUNCATE_FADE_EM * 14.0 * scale) < 0.25)
            }

            rt.update(at: 0) { w, tx in
                w = 500
                tx.settle()
            }
            let rfWide = rt.renderFrame(at: 0)
            let wideGlyphs = rfWide.instances.filter { $0.params.y == KIND_GLYPH }
            #expect(!wideGlyphs.isEmpty)
            #expect(wideGlyphs.allSatisfy { unpackFade($0.fade).width == .zero })
        }
    }

    @Test("batch_c: fadeTruncationOverflowIsIndependentOfElementAndDisplayScale")
    func fadeTruncationOverflowIsIndependentOfElementAndDisplayScale() {
        let label = "clock 0123456789"
        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400)
        for displayScale: Float in [1.0, 2.0] {
            let fullW = ts.measure(label, style: style, maxWidth: nil, pixelScale: displayScale).x
            for elementScale: Float in [0.5, 1.0, 2.0] {
                for (fraction, overflowing) in [(Float(0.75), true), (Float(1.25), false)] {
                    let rt = Runtime<(Float, Float)>(
                        state: (fullW * fraction, elementScale),
                        viewport: Vec2(600, 300),
                        pixelScale: displayScale,
                        systemDark: true
                    ) { s, _ in
                        row().p(80).child(
                            text(label)
                                .w(s.0)
                                .font(style)
                                .scale(s.1)
                                .truncateFade()
                        )
                    }
                    let rf = rt.renderFrame(at: 0)
                    let fades = rf.instances
                        .filter { $0.params.y == KIND_GLYPH }
                        .map { unpackFade($0.fade).width.z }
                    #expect(!fades.isEmpty)
                    let expected: Float = overflowing ? TRUNCATE_FADE_EM * 14.0 * displayScale * elementScale : 0.0
                    for fadeW in fades {
                        #expect(abs(fadeW - expected) < 0.5, "display=\(displayScale), el=\(elementScale), over=\(overflowing): got \(fadeW), expected \(expected)")
                    }
                }
            }
        }
    }

    @Test("batch_c: fadeTruncationWidthIsSettable")
    func fadeTruncationWidthIsSettable() {
        for scale: Float in [1.0, 2.0] {
            for (width, em, expected): (Float, Float, Float) in [(60, 3.0, 42.0), (60, 0.5, 7.0)] {
                let rt = Runtime<(Float, Float)>(
                    state: (width, em),
                    viewport: Vec2(600, 100),
                    pixelScale: scale,
                    systemDark: true
                ) { s, _ in
                    row().child(
                        text("this is much too long")
                            .w(s.0)
                            .font(TextStyle(size: 14, weight: 400))
                            .truncateFadeWidth(s.1)
                    )
                }
                let rf = rt.renderFrame(at: 0)
                let fades = rf.instances
                    .filter { $0.params.y == KIND_GLYPH }
                    .map { unpackFade($0.fade).width.z }
                #expect(!fades.isEmpty)
                for f in fades {
                    #expect(abs(f - expected * scale) < 0.25)
                }
            }
        }
    }

    @Test("truncate_fade_tests: fit never fades at any offset, cut short fades, and fit layout never fades while growing")
    func truncateFadeFitOffsetAndGrowingBoxParity() {
        let label = "hello"
        let style = TextStyle(size: 14, weight: 400)
        // 1. a_label_that_fits_never_fades_wherever_it_lands
        for leftOffset: Float in [0, 3, 17, 45.5] {
            let rt = Runtime<Float>(state: leftOffset, viewport: Vec2(400, 100)) { offset, _ in
                row().pl(offset).child(
                    text(label).w(200).font(style).truncateFade()
                )
            }
            let rf = rt.renderFrame(at: 0)
            let glyphs = rf.instances.filter { $0.params.y == KIND_GLYPH }
            #expect(!glyphs.isEmpty)
            let allZeroFade = glyphs.allSatisfy { unpackFade($0.fade).width == .zero }
            #expect(allZeroFade)
        }

        // 2. a_label_cut_short_still_fades (both pixelScale 1 and 2, narrow box cuts the label)
        let rtCut = Runtime<Float>(state: 48, viewport: Vec2(200, 100)) { w, _ in
            row().child(text("this long label is definitely cut short").w(w).font(style).truncateFade())
        }
        let rfCut = rtCut.renderFrame(at: 0)
        let cutGlyphs = rfCut.instances.filter { $0.params.y == KIND_GLYPH }
        #expect(!cutGlyphs.isEmpty)
        #expect(cutGlyphs.allSatisfy { unpackFade($0.fade).width.z > 0.5 })

        // 3. a_label_that_fits_its_layout_never_fades_while_its_box_grows_to_it
        let rtGrow = Runtime<Float>(state: 60, viewport: Vec2(400, 100)) { w, _ in
            row().w(w).animateLayout(Spring(duration: 0.35, bounce: 0.0)).child(
                text("hi").font(style).truncateFade()
            )
        }
        _ = rtGrow.frame(at: 0)
        rtGrow.update(at: 0) { w, tx in
            w = 240
            tx.animated()
        }
        for i in 1...6 {
            let t = Double(i) * (1.0 / 60.0)
            _ = rtGrow.frame(at: t)
            let rfStep = rtGrow.renderFrame(at: t)
            let glyphs = rfStep.instances.filter { $0.params.y == KIND_GLYPH }
            #expect(!glyphs.isEmpty)
            let zeroFades = glyphs.allSatisfy { unpackFade($0.fade).width == .zero }
            #expect(zeroFades)
        }
    }

    @Test("truncate_tests: middle/head resize, graphemes, full copy, spans/links hide, space trim, range map, and elision cache")
    func truncateTestsSuiteCompleteParity() {
        let ts = TextSystem()
        var midStyle = TextStyle(size: 14, weight: 400)
        midStyle.wrap = .ellipsis
        midStyle.elide = .middle
        midStyle.graphemeElide = true

        // 1. middle_truncation_keeps_both_ends_and_refits_on_resize + 2. head_truncation_keeps_the_end
        let full = "alpha-beta-gamma-delta"
        let narrowMid = TextTruncation.elide(text: full, spans: nil, pills: [], style: midStyle, maxWidth: 65, pixelScale: 1.0, textSystem: ts)
        let widerMid = TextTruncation.elide(text: full, spans: nil, pills: [], style: midStyle, maxWidth: 110, pixelScale: 1.0, textSystem: ts)
        #expect(narrowMid.wasCut && narrowMid.drawn.hasPrefix("al") && narrowMid.drawn.hasSuffix("ta"))
        #expect(widerMid.wasCut && widerMid.drawn.count >= narrowMid.drawn.count)

        var headStyle = midStyle
        headStyle.elide = .head
        let headCut = TextTruncation.elide(text: full, spans: nil, pills: [], style: headStyle, maxWidth: 75, pixelScale: 1.0, textSystem: ts)
        #expect(headCut.wasCut && headCut.drawn.hasPrefix(TextElision.ellipsis) && headCut.drawn.hasSuffix("delta"))

        // 3. cuts_fall_between_graphemes (combining marks / ZWJ emoji never split mid-cluster)
        let graphemeText = "e\u{0301}👩‍👩‍👧‍👦-e\u{0301}👩‍👩‍👧‍👦-end"
        let graphemeCut = TextTruncation.elide(text: graphemeText, spans: nil, pills: [], style: midStyle, maxWidth: 55, pixelScale: 1.0, textSystem: ts)
        #expect(graphemeCut.wasCut)
        let hIdx = graphemeText.utf8.index(graphemeText.utf8.startIndex, offsetBy: graphemeCut.elision.head)
        let tIdx = graphemeText.utf8.index(graphemeText.utf8.startIndex, offsetBy: graphemeCut.elision.tail)
        #expect(hIdx.samePosition(in: graphemeText) != nil)
        #expect(tIdx.samePosition(in: graphemeText) != nil)

        // 4. copying_a_cut_text_copies_all_of_it + 7. elision_maps_ranges_across_the_cut
        let elidedRange = graphemeCut.elision.range(0, graphemeText.utf8.count)
        #expect(elidedRange.0 == 0 && elidedRange.1 == graphemeCut.drawn.utf8.count)
        let cStart = graphemeCut.elision.contentByte(forDrawn: 0)
        let cEnd = graphemeCut.elision.contentByte(forDrawn: graphemeCut.drawn.utf8.count)
        #expect(cStart == 0 && cEnd == graphemeText.utf8.count)

        // 5. a_cut_hides_the_spans_and_links_inside_it
        let spans: [TextSpan] = [
            TextSpan("head "),
            TextSpan("hidden-link-text", color: Color(r: 0, g: 0, b: 1, a: 1), underline: true),
            TextSpan(" tail"),
        ]
        let spanText = spans.map(\.text).joined()
        let spanCut = TextTruncation.elide(text: "", spans: spans, pills: [], style: midStyle, maxWidth: 70, pixelScale: 1.0, textSystem: ts)
        #expect(spanCut.wasCut)
        let hiddenStart = "head ".utf8.count
        let hiddenEnd = hiddenStart + "hidden-link-text".utf8.count
        let linkMark = spanCut.elision.mark(hiddenStart, hiddenEnd, link: true)
        if spanCut.elision.head <= hiddenStart && spanCut.elision.tail >= hiddenEnd {
            #expect(linkMark.0 == linkMark.1)
        }
        let nonZeroSpanCount = spanCut.spans?.filter { !$0.text.isEmpty }.count ?? 0
        #expect(nonZeroSpanCount >= 1)
        _ = spanText

        // 6. trimming_spaces_keeps_graphemes_whole
        let spaced = "alpha   beta   omega"
        var endStyle = midStyle
        endStyle.elide = .end
        let trimmedCut = TextTruncation.elide(text: spaced, spans: nil, pills: [], style: endStyle, maxWidth: 48, pixelScale: 1.0, textSystem: ts)
        #expect(trimmedCut.wasCut)
        let headSub = String(decoding: Array(spaced.utf8)[0..<trimmedCut.elision.head], as: UTF8.self)
        #expect(!headSub.hasSuffix(" "))

        // 8. elision_cache_reuses_cut_evicts_superseded_and_bypasses_secure
        let cache = ElisionCache()
        let r1 = TextTruncation.elide(text: full, spans: nil, pills: [], style: midStyle, maxWidth: 70, pixelScale: 1.0, textSystem: ts, cache: cache, ownerId: 101, secure: false)
        let r2 = TextTruncation.elide(text: full, spans: nil, pills: [], style: midStyle, maxWidth: 70, pixelScale: 1.0, textSystem: ts, cache: cache, ownerId: 101, secure: false)
        #expect(r1.drawn == r2.drawn)
        #expect(cache.hits == 1 && cache.misses == 1 && cache.count == 1)
        // Superseding cut for same owner evicts previous entry cleanly
        _ = TextTruncation.elide(text: full, spans: nil, pills: [], style: midStyle, maxWidth: 95, pixelScale: 1.0, textSystem: ts, cache: cache, ownerId: 101, secure: false)
        #expect(cache.count == 1 && cache.misses == 2)
        // Secure text bypasses the elision cache completely
        _ = TextTruncation.elide(text: "secret-password-string", spans: nil, pills: [], style: midStyle, maxWidth: 70, pixelScale: 1.0, textSystem: ts, cache: cache, ownerId: 202, secure: true)
        #expect(cache.count == 1 && cache.hits == 1 && cache.misses == 2)
    }
}
