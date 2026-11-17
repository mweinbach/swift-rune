import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Rune

/// up-text-3: upstream `31bc675b` (#1023, pretty wrapping keeps the greedy breaks of a paragraph
/// with a line that holds no text) and `f6cf57db` (#991, the 2x font fixture follows inline code's
/// line box, the test half of `6ece36ad` #983).
@Suite("Up-text-3 parity: pretty wrap box-only lines (#1023), 2x inline code line box fixture (#991)", .serialized)
struct UpText3ParityTests {

    // MARK: - #1023: a paragraph with a line that holds only an inline box keeps its greedy breaks

    private static let paragraph = "Careful typography avoids leaving a single short trailing word alone at the bottom of a long paragraph."

    /// Greedy lines of `shaped[from...]` broken by CoreText at `widthPx`, as `TextSystem` hands
    /// them to the pretty breaker (absolute string indices, `strIndexBase` 0).
    private static func greedyLines(
        typesetter: CTTypesetter,
        in ns: NSString,
        from start: Int,
        widthPx: Double
    ) -> [PrettyLineBreaker.GreedyLineInfo] {
        var out: [PrettyLineBreaker.GreedyLineInfo] = []
        var cursor = start
        while cursor < ns.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, cursor, widthPx))
            out.append(lineInfo(typesetter: typesetter, start: cursor, count: count))
            cursor += count
        }
        return out
    }

    private static func lineInfo(typesetter: CTTypesetter, start: Int, count: Int) -> PrettyLineBreaker.GreedyLineInfo {
        let line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, count))
        return PrettyLineBreaker.GreedyLineInfo(
            u16Start: start,
            u16End: start + count,
            widthPx: Float(CTLineGetTypographicBounds(line, nil, nil, nil)),
            trailingWsPx: Float(CTLineGetTrailingWhitespaceWidth(line)),
            hasRTLRun: false,
            ctLine: line,
            strIndexBase: 0
        )
    }

    private static func typesetter(_ s: String, font: CTFont) -> CTTypesetter {
        let attr = CFAttributedStringCreate(kCFAllocatorDefault, s as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        return CTTypesetterCreateWithAttributedString(attr)
    }

    @Test("#1023: sliceable lines are valid ranges that hold text; a box-only line is not")
    func sliceableLines() throws {
        let ns = "ab \u{FFFC}cd\u{FFFC}" as NSString
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let ts = Self.typesetter(ns as String, font: font)
        func info(_ start: Int, _ end: Int) -> PrettyLineBreaker.GreedyLineInfo {
            var l = Self.lineInfo(typesetter: ts, start: 0, count: ns.length)
            l.u16Start = start
            l.u16End = end
            return l
        }
        let boxes: Set<Int> = [3, 6]
        #expect(PrettyLineBreaker.isSliceable(info(0, 3), in: ns, boxU16: boxes), "text")
        #expect(PrettyLineBreaker.isSliceable(info(2, 5), in: ns, boxU16: boxes), "a box with text")
        #expect(PrettyLineBreaker.isSliceable(info(2, 2), in: ns, boxU16: boxes), "an empty range in bounds")
        #expect(!PrettyLineBreaker.isSliceable(info(6, 7), in: ns, boxU16: boxes), "only an inline box")
        #expect(!PrettyLineBreaker.isSliceable(info(3, 4), in: ns, boxU16: boxes), "only an inline box")
        // Parley's box-only line: an empty range at `usize::MAX`, past the text.
        #expect(!PrettyLineBreaker.isSliceable(info(Int.max, Int.max), in: ns, boxU16: boxes))
        #expect(!PrettyLineBreaker.isSliceable(info(5, 4), in: ns, boxU16: boxes), "start > end")
        #expect(!PrettyLineBreaker.isSliceable(info(0, ns.length + 1), in: ns, boxU16: boxes), "end past the text")
        // Without box positions the placeholder is just a unit of text.
        #expect(PrettyLineBreaker.isSliceable(info(6, 7), in: ns, boxU16: []))
    }

    @Test("#1023: pretty wrapping keeps the greedy breaks of a paragraph with a line that holds only an inline box")
    func boxOnlyLineKeepsGreedyBreaks() throws {
        #expect(DefaultFonts.registerIfNeeded())
        let system = TextSystem()
        let style = TextStyle(size: 14, weight: 400).wrapped()
        let font = system.resolveCTFont(style: style, pixelScale: 1)
        // Long enough to wrap over more than the 4 lines the breaker scores.
        let paragraph = "Careful typography avoids leaving a single short trailing word alone at the bottom of a long paragraph, so the eye moves on to the next one without a stop."
        let plainNS = paragraph as NSString
        let plainTS = Self.typesetter(paragraph, font: font)
        // A line holding only a pill's box, then the paragraph: the box is its own (first) line.
        let boxedText = "\u{FFFC}" + paragraph
        let boxedNS = boxedText as NSString
        let boxedTS = Self.typesetter(boxedText, font: font)

        // A width where the plain paragraph's greedy last line is a lone short word over 4+ lines,
        // which the pretty breaker re-breaks.
        var found: (width: Float, plainCaps: [Int: CGFloat])? = nil
        for wInt in stride(from: 80, through: 400, by: 2) {
            let w = Float(wInt)
            let lines = Self.greedyLines(typesetter: plainTS, in: plainNS, from: 0, widthPx: Double(w))
            guard lines.count >= 4,
                  let caps = PrettyLineBreaker.prettyLineCaps(lines: lines, in: plainNS, fontSizePt: 14, scale: 1, maxWidthPx: w)
            else { continue }
            found = (w, caps)
            break
        }
        let (width, plainCaps) = try #require(found, "a width where the plain paragraph wraps prettily")
        #expect(!plainCaps.isEmpty)

        // The same lines after a box-only line (outside the last 4 lines the breaker scores):
        // the box line can't be sliced, so the paragraph keeps its greedy breaks.
        let paraLines = Self.greedyLines(typesetter: boxedTS, in: boxedNS, from: 1, widthPx: Double(width))
        #expect(paraLines.map { $0.u16Start - 1 } == Self.greedyLines(typesetter: plainTS, in: plainNS, from: 0, widthPx: Double(width)).map(\.u16Start))
        let boxLine = Self.lineInfo(typesetter: boxedTS, start: 0, count: 1)
        let withBoxLine = [boxLine] + paraLines
        #expect(PrettyLineBreaker.prettyLineCaps(lines: withBoxLine, in: boxedNS, fontSizePt: 14, scale: 1, maxWidthPx: width, boxU16: [0]) == nil)
        // The placeholder as text (no box there) is sliceable: the paragraph wraps prettily again,
        // as the plain one does, one line down.
        let asText = try #require(PrettyLineBreaker.prettyLineCaps(lines: withBoxLine, in: boxedNS, fontSizePt: 14, scale: 1, maxWidthPx: width, boxU16: []))
        #expect(Set(asText.keys) == Set(plainCaps.keys.map { $0 + 1 }))

        // A box-only last line keeps the greedy breaks too.
        let tailText = paragraph + "\u{FFFC}"
        let tailNS = tailText as NSString
        let tailTS = Self.typesetter(tailText, font: font)
        var tailLines = Self.greedyLines(typesetter: tailTS, in: tailNS, from: 0, widthPx: Double(width))
            .filter { $0.u16Start < plainNS.length }
        tailLines[tailLines.count - 1] = Self.lineInfo(typesetter: tailTS, start: tailLines[tailLines.count - 1].u16Start, count: plainNS.length - tailLines[tailLines.count - 1].u16Start)
        tailLines.append(Self.lineInfo(typesetter: tailTS, start: plainNS.length, count: 1))
        #expect(PrettyLineBreaker.prettyLineCaps(lines: tailLines, in: tailNS, fontSizePt: 14, scale: 1, maxWidthPx: width, boxU16: [plainNS.length]) == nil)
    }

    @Test("#1023: paragraphs with pills still wrap prettily when every line holds text")
    func pillParagraphStillWrapsPrettily() throws {
        defer { TextSystem.setPrettyWrap(false) }
        #expect(DefaultFonts.registerIfNeeded())
        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400).wrapped()
        let label = "typography"
        let start = try #require(Self.paragraph.range(of: label))
        let lo = Self.paragraph.utf8.distance(from: Self.paragraph.startIndex, to: start.lowerBound)
        let pills = [PillChip(lo..<(lo + label.utf8.count))]
        var checked = 0
        TextSystem.setPrettyWrap(true)
        for wInt in stride(from: 130, through: 360, by: 2) {
            let w = Float(wInt)
            let greedy = ts.shape(text: Self.paragraph, pills: pills, style: style, maxWidth: w, pixelScale: 1.0, emitGlyphs: false, pretty: false)
            guard greedy.lineCount >= 3, let last = greedy.lineStrings.last?.text else { continue }
            let t = last.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.contains(" "), greedy.lineAdvancePx(at: greedy.lineCount - 1) < w / 3.0 else { continue }
            // Every line holds text (the pill's boxes sit with its label).
            #expect(greedy.lineStrings.allSatisfy { !$0.text.isEmpty })
            let pretty = ts.shape(text: Self.paragraph, pills: pills, style: style, maxWidth: w, pixelScale: 1.0, emitGlyphs: false, pretty: true)
            #expect(pretty.lineCount == greedy.lineCount)
            let words = (pretty.lineStrings.last?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            #expect(words.count >= 2, "width \(w): \(pretty.lineStrings.map(\.text))")
            checked += 1
        }
        #expect(checked > 0)
    }

    // MARK: - #991: the 2x font fixture follows inline code's line box (`font_families.rs`)

    /// `default_faces_keep_batch_c_pixels`: "Hello 0123 ffi" with a mono span over `0123`.
    private static let fixtureText = "Hello 0123 ffi"
    private static let fixtureSpans = [TextSpan("Hello "), TextSpan("0123", monospace: true), TextSpan(" ffi")]

    @Test("#991: at 2x the inline Plex span grows the 13 px Inter line, as at 1x (Chromium's quantized boxes)")
    func defaultFacesInlineCodeLineBox() throws {
        #expect(DefaultFonts.registerIfNeeded())
        let ts = TextSystem()
        ts.smoothing = .on
        let sans = TextStyle(size: 13, weight: 400)
        var mono = sans
        mono.family = .monospace
        #expect(sans.resolvedLineHeight == 16.25, "line_height 0: size * 1.25")
        let sansFont = ts.resolveCTFont(style: sans, pixelScale: 1)
        let monoFont = ts.resolveCTFont(style: mono, pixelScale: 1)
        #expect((CTFontCopyFamilyName(sansFont) as String).contains("Inter"))
        #expect((CTFontCopyFamilyName(monoFont) as String).contains("Plex"))

        // Inter (ascender 0.96875, descender 0.2412 em) and IBM Plex Mono (1.025, 0.275 em) at 13 px,
        // in a 16.25 px line: Plex reaches a pixel further under the baseline at 1x (17.25 px line)
        // and, its half-leading floored, a pixel further over it at 2x (33.5 device px).
        let want: [(scale: Float, over: Float, under: Float)] = [(1, 0, 1), (2, 1, 0)]
        for (scale, over, under) in want {
            let lh = 16.25 * scale
            let g = InlineCodeBox.lineGrowth(strut: (13 * scale * 0.96875, 13 * scale * 0.2412), code: [(13 * scale * 1.025, 13 * scale * 0.275, lh)], lineHeightPx: lh)
            #expect(g == (over, under), "\(scale)x growth \(g)")

            let plain = ts.shape(text: Self.fixtureText, style: sans, maxWidth: nil, pixelScale: scale, emitGlyphs: true)
            let code = ts.shape(text: Self.fixtureText, spans: Self.fixtureSpans, style: sans, maxWidth: nil, pixelScale: scale, emitGlyphs: true)
            #expect(plain.lineMetricHeightPt(0) * scale == lh)
            #expect(abs(code.lineMetricHeightPt(0) * scale - (lh + over + under)) < 1e-3,
                    "\(scale)x: the code line is \(code.lineMetricHeightPt(0) * scale) px, want \(lh + over + under)")
            // The layout is as tall as its unrounded line (`spec_height` to 1/64 px).
            #expect(code.size.y * scale == lh + over + under, "\(scale)x: \(code.size.y * scale) px")
            #expect(code.size.y > plain.size.y, "\(scale)x: inline code grows the line")

            // The glyphs sit on the shared baseline: Parley's `top + over`, the strut's quantized
            // reach plus the code's growth (25 + 1 = 26 device px at 2x), never above the plain
            // line's. At 1x the code only grows the line under the baseline, so its pixels don't move.
            let strutOver = InlineCodeBox.quantizedBox(ascentPx: 13 * scale * 0.96875, descentPx: 13 * scale * 0.2412, lineHeightPx: lh).over
            #expect(plain.lineBaselinesPx == [strutOver])
            #expect(code.lineBaselinesPx == [strutOver + over])
            if scale == 2 { #expect(strutOver + over == 26) }
            let plainY = plain.glyphs.prefix(5).map { $0.rect.y * scale }
            let codeY = code.glyphs.prefix(5).map { $0.rect.y * scale }
            #expect(plainY.count == 5 && codeY.count == 5)
            #expect(zip(codeY, plainY).allSatisfy { abs($0 - $1 - over) < 1e-3 }, "\(scale)x: \(codeY) vs \(plainY)")
            if scale == 1 { #expect(codeY == plainY, "1x pixels don't change") }

            // A Plex Mono paragraph's mono span is its own font: no growth.
            let monoPlain = ts.shape(text: Self.fixtureText, style: mono, maxWidth: nil, pixelScale: scale, emitGlyphs: true)
            let monoCode = ts.shape(text: Self.fixtureText, spans: Self.fixtureSpans, style: mono, maxWidth: nil, pixelScale: scale, emitGlyphs: true)
            #expect(monoCode.size.y == monoPlain.size.y)
            #expect(monoCode.lineMetricHeightPt(0) * scale == lh)
        }
    }
}
