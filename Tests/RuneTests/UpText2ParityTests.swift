import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Rune

/// up-text-2: upstream `c2476f2d` (#933 pretty wrap for pills and `wrap_anywhere`),
/// `6ece36ad` (#983 inline code's line box and chip) and `e1263a8a` (#954 `AppleFontSmoothing` 0).
@Suite("Up-text-2 parity: pretty pills/wrapAnywhere (#933), inline code box (#983), AppleFontSmoothing (#954)", .serialized)
struct UpText2ParityTests {

    // MARK: - #933: pretty wrapping covers pills and wrap_anywhere text

    private static let paragraph = "Careful typography avoids leaving a single short trailing word alone at the bottom of a long paragraph."

    private static func lastWords(_ s: ShapedText) -> [Substring] {
        (s.lineStrings.last?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    }

    /// A width where greedy breaking leaves only one short word on the last line.
    private static func orphanWidth(ts: TextSystem, text: String, pills: [PillChip] = [], style: TextStyle) -> Float? {
        for wInt in stride(from: 130, through: 360, by: 2) {
            let w = Float(wInt)
            let s = ts.shape(text: text, pills: pills, style: style, maxWidth: w, pixelScale: 1.0, emitGlyphs: false, pretty: false)
            guard s.lineCount >= 3, let last = s.lineStrings.last?.text else { continue }
            let t = last.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !t.contains(" "), s.lineAdvancePx(at: s.lineCount - 1) < w / 3.0 {
                return w
            }
        }
        return nil
    }

    @Test("#933: a paragraph with a pill wraps prettily (TextSpec.pretty no longer needs plain text)")
    func prettyWrapsParagraphsWithPills() throws {
        defer { TextSystem.setPrettyWrap(false) }
        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400).wrapped()
        let label = "typography"
        let start = try #require(Self.paragraph.range(of: label))
        let lo = Self.paragraph.utf8.distance(from: Self.paragraph.startIndex, to: start.lowerBound)
        let pills = [PillChip(lo..<(lo + label.utf8.count))]
        let width = try #require(Self.orphanWidth(ts: ts, text: Self.paragraph, pills: pills, style: style))

        let greedy = ts.shape(text: Self.paragraph, pills: pills, style: style, maxWidth: width, pixelScale: 1.0, emitGlyphs: false, pretty: false)
        #expect(Self.lastWords(greedy).count == 1)
        TextSystem.setPrettyWrap(true)
        let pretty = ts.shape(text: Self.paragraph, pills: pills, style: style, maxWidth: width, pixelScale: 1.0, emitGlyphs: false, pretty: true)
        #expect(pretty.lineCount == greedy.lineCount, "pretty keeps the greedy line count")
        #expect(Self.lastWords(pretty).count >= 2, "the pill paragraph pulls a word down: \(pretty.lineStrings.map(\.text))")
        #expect(pretty.pillChips.count == greedy.pillChips.count)
        #expect(pretty.lineStrings.map(\.text).joined() == greedy.lineStrings.map(\.text).joined())
    }

    @Test("#933: wrapAnywhere text wraps prettily when no word breaks inside, and El text resolves pretty")
    @MainActor
    func prettyWrapsWrapAnywhereText() throws {
        defer { TextSystem.setPrettyWrap(false) }
        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400).wrapped().wrapAnywhere()
        #expect(TextShapeKey.layoutPretty(true, style: style), "layout_keyed: pretty && max_width && !mono")
        let width = try #require(Self.orphanWidth(ts: ts, text: Self.paragraph, style: style))
        let greedy = ts.shape(text: Self.paragraph, style: style, maxWidth: width, pixelScale: 1.0, emitGlyphs: false, pretty: false)
        #expect(Self.lastWords(greedy).count == 1)
        TextSystem.setPrettyWrap(true)
        let pretty = ts.shape(text: Self.paragraph, style: style, maxWidth: width, pixelScale: 1.0, emitGlyphs: false, pretty: true)
        #expect(pretty.lineCount == greedy.lineCount)
        #expect(Self.lastWords(pretty).count >= 2, "\(pretty.lineStrings.map(\.text))")

        // `TextSpec.pretty`: greedy, redacted and justify opt out; wrap_anywhere no longer does.
        let el: El<Int> = Rune.text(Self.paragraph).font(style).w(width)
        let resolved = ElDisplayResolver.resolveText(el: el, rawText: Self.paragraph, isSecure: false)
        #expect(resolved.pretty == true)
        let greedyEl = ElDisplayResolver.resolveText(el: el.wrapGreedy(), rawText: Self.paragraph, isSecure: false)
        #expect(greedyEl.pretty == false)
        let justifiedEl: El<Int> = Rune.text(Self.paragraph).font(style.aligned(.justified)).w(width)
        let justified = ElDisplayResolver.resolveText(el: justifiedEl, rawText: Self.paragraph, isSecure: false)
        #expect(justified.pretty == false)
    }

    @Test("#933: a wrapAnywhere paragraph with a word broken inside to fit keeps its greedy lines (RetryAfterOverflow)")
    func emergencyBreakKeepsGreedyLines() throws {
        defer { TextSystem.setPrettyWrap(false) }
        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400).wrapped().wrapAnywhere()
        let text = "Paste Abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz into the box and see it end on a lone word."
        var checked = 0
        TextSystem.setPrettyWrap(true)
        for wInt in stride(from: 90, through: 300, by: 2) {
            let w = Float(wInt)
            let greedy = ts.shape(text: text, style: style, maxWidth: w, pixelScale: 1.0, emitGlyphs: false, pretty: false)
            let lines = greedy.lineStrings.map(\.text)
            guard lines.count >= 3 else { continue }
            // A line ending between two letters: the long word broken inside (`BreakReason::Emergency`).
            let broken = zip(lines, lines.dropFirst()).contains { a, b in
                guard let l = a.unicodeScalars.last, let f = b.unicodeScalars.first else { return false }
                return CharacterSet.letters.contains(l) && CharacterSet.letters.contains(f)
            }
            let last = (lines.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard broken, !last.contains(" "), greedy.lineAdvancePx(at: greedy.lineCount - 1) < w / 3.0 else { continue }
            let pretty = ts.shape(text: text, style: style, maxWidth: w, pixelScale: 1.0, emitGlyphs: false, pretty: true)
            #expect(pretty.lineStrings.map(\.text) == lines, "width \(w)")
            checked += 1
        }
        #expect(checked > 0, "found a width with an emergency break and a lone last word")
    }

    @Test("#933: an inline box is a cluster at its position; a break there lands before the box")
    func breakOpportunitiesSkipInlineBoxes() {
        // "ab ␣cd␣ ef" with pill placeholders at 3 and 6.
        let ns = "ab \u{FFFC}cd\u{FFFC} ef" as NSString
        let breaks = PrettyLineBreaker.lineBreakOpportunities(in: ns, from: 0, to: ns.length, boxU16: [3, 6])
        #expect(breaks == [3, 8], "the break after `ab ` starts the next line with the box: \(breaks)")
        #expect(!breaks.contains(4), "no break between a box and its label")
        // Without boxes the text breaks after its spaces, as before.
        let plain = "ab cd ef" as NSString
        #expect(PrettyLineBreaker.lineBreakOpportunities(in: plain, from: 0, to: plain.length) == [3, 6])
    }

    // MARK: - #983: inline code grows its line; its chip is the code font's box

    @Test("#983: decorations.rs background boxes: mono content area, others on the cap height")
    func backgroundVerticalBoxes() {
        let mono = InlineCodeBox.backgroundVertical(baselinePx: 20.4, mono: true, ascentPx: 13.3, descentPx: 3.6, capHeightPx: 9.0, fontSizePx: 13)
        #expect(mono.top == 7 && mono.bottom == 24)
        let sans = InlineCodeBox.backgroundVertical(baselinePx: 20, mono: false, ascentPx: 12.6, descentPx: 3.1, capHeightPx: 9.4, fontSizePx: 13)
        #expect(sans.top == 7 && sans.bottom == 25)
        let noCap = InlineCodeBox.backgroundVertical(baselinePx: 20, mono: false, ascentPx: 9, descentPx: 2, capHeightPx: nil, fontSizePx: 10)
        #expect(noCap.top == 11 && noCap.bottom == 24)
    }

    @Test("#983: Parley's quantized boxes: 13/16 Plex Mono reaches 4 under the baseline where Inter reaches 3")
    func quantizedBoxesAndGrowth() {
        // Inter (ascender 0.96875, descender 0.2412 em) and IBM Plex Mono (1.025, 0.275 em) at 13 px.
        #expect(InlineCodeBox.quantizedBox(ascentPx: 13 * 0.96875, descentPx: 13 * 0.2412, lineHeightPx: 16) == (13, 3))
        #expect(InlineCodeBox.quantizedBox(ascentPx: 13 * 1.025, descentPx: 13 * 0.275, lineHeightPx: 16) == (12, 4))
        let g1 = InlineCodeBox.lineGrowth(strut: (13 * 0.96875, 13 * 0.2412), code: [(13 * 1.025, 13 * 0.275)], lineHeightPx: 16)
        #expect(g1 == (0, 1), "a 13/16 line with code is 17 tall at 1x")
        let g2 = InlineCodeBox.lineGrowth(strut: (26 * 0.96875, 26 * 0.2412), code: [(26 * 1.025, 26 * 0.275)], lineHeightPx: 32)
        #expect(g2.over + g2.under == 1, "33 device px at 2x")
        for s: Float in [1.25, 1.5, 1.875] {
            let g = InlineCodeBox.lineGrowth(strut: (13 * s * 0.96875, 13 * s * 0.2412), code: [(13 * s * 1.025, 13 * s * 0.275)], lineHeightPx: 16 * s)
            #expect(g.over + g.under == 0, "16 tall at \(s)x")
        }
        #expect(InlineCodeBox.lineGrowth(strut: (12.6, 3.1), code: [], lineHeightPx: 16) == (0, 0))
    }

    private static func codeSpans(_ size: Float? = nil) -> [TextSpan] {
        [TextSpan("a table cell with "), TextSpan("code", monospace: true, size: size), TextSpan(" in it")]
    }

    @Test("#983: a 13/16 cell with Plex Mono code is 17 tall at 1x and 2x, 16 at 1.25x, 1.5x and 1.875x")
    func inlineCodeGrowsItsLine() throws {
        #expect(DefaultFonts.registerIfNeeded())
        let ts = TextSystem()
        let style = TextStyle(size: 13, weight: 400, lineHeight: 16)
        let sans = ts.resolveCTFont(style: style, pixelScale: 1)
        var monoStyle = style
        monoStyle.family = .monospace
        let mono = ts.resolveCTFont(style: monoStyle, pixelScale: 1)
        #expect((CTFontCopyFamilyName(sans) as String).contains("Inter"))
        #expect((CTFontCopyFamilyName(mono) as String).contains("Plex"))

        let text = Self.codeSpans().map(\.text).joined()
        let want: [(scale: Float, heightPx: Float)] = [(1, 17), (2, 33), (1.25, 20), (1.5, 24), (1.875, 30)]
        for (scale, heightPx) in want {
            let plain = ts.shape(text: text, style: style, maxWidth: nil, pixelScale: scale, emitGlyphs: false)
            #expect(plain.size.y * scale == 16 * scale, "plain text keeps the strut at \(scale)x")
            let code = ts.shape(text: text, spans: Self.codeSpans(), style: style, maxWidth: nil, pixelScale: scale, emitGlyphs: true)
            #expect(code.size.y * scale == heightPx, "\(scale)x: \(code.size.y * scale) px")
        }

        // Two lines, code on the first: the second line starts where the grown first ends, and
        // hit-testing finds it there.
        let twoLines = text + "\nsecond line"
        let spans = Self.codeSpans() + [TextSpan("\nsecond line")]
        let shaped = ts.shape(text: twoLines, spans: spans, style: style, maxWidth: nil, pixelScale: 1, emitGlyphs: true)
        #expect(shaped.lineCount == 2)
        #expect(shaped.size.y == 33)
        #expect(shaped.grownLineTopsPt == [0, 17])
        #expect(shaped.lineStrings[1].originY == 17)
        let hit = ts.hitTestUTF8Offset(in: shaped, localX: 0.5, localY: 16.5, pixelScale: 1)
        #expect(hit < text.utf8.count, "16.5 pt is still the grown first line")
        let hit2 = ts.hitTestUTF8Offset(in: shaped, localX: 0.5, localY: 17.5, pixelScale: 1)
        #expect(hit2 >= text.utf8.count + 1, "17.5 pt is the second line")
        #expect(shaped.bandLineHeight == 0, "no uniform-band glyph culling once lines grew")
    }

    @Test("#983: inline code's chip is its font's content area; padding spaces share one chip at the code's height")
    func inlineCodeAndItsPaddingShareOneChip() throws {
        #expect(DefaultFonts.registerIfNeeded())
        let ts = TextSystem()
        let bg = Color.black.alpha(0.08)
        let style = TextStyle(size: 13, weight: 400)
        // `quality_tests.rs::inline_code_and_its_padding_share_one_chip`.
        let spans = [
            TextSpan("say "),
            TextSpan("\u{202F}", background: bg),
            TextSpan("code", background: bg, monospace: true, size: 13 * 0.9),
            TextSpan("\u{202F}", background: bg),
            TextSpan(" now"),
        ]
        let content = spans.map(\.text).joined()
        let all = ts.shape(text: content, spans: spans, style: style, maxWidth: nil, pixelScale: 2.0, emitGlyphs: true)
        #expect(all.backgrounds.count == 1, "\(all.backgrounds.map(\.0))")
        let codeOnly = [TextSpan("say \u{202F}"), spans[2], TextSpan("\u{202F} now")]
        let alone = ts.shape(text: content, spans: codeOnly, style: style, maxWidth: nil, pixelScale: 2.0, emitGlyphs: true)
        #expect(alone.backgrounds.count == 1)
        let a = try #require(all.backgrounds.first?.0)
        let b = try #require(alone.backgrounds.first?.0)
        #expect(a.y == b.y && a.w == b.w, "the code's height")
        #expect(a.z > b.z, "padding widens it")

        // The code's box: round(ascent) + round(descent) of its font, in device px.
        var monoStyle = style
        monoStyle.family = .monospace
        monoStyle.size = 13 * 0.9
        let mono = ts.resolveCTFont(style: monoStyle, pixelScale: 2.0)
        let expectH = Float(CTFontGetAscent(mono)).rounded() + Float(CTFontGetDescent(mono)).rounded()
        #expect(b.w * 2.0 == expectH)

        // A plain (non-mono) background balances on the cap height: (base - cap*1.35) .. (base + cap*0.55).
        let mark = [TextSpan("say "), TextSpan("mark", background: bg), TextSpan(" now")]
        let marked = ts.shape(text: content, spans: mark, style: style, maxWidth: nil, pixelScale: 2.0, emitGlyphs: true)
        let m = try #require(marked.backgrounds.first?.0)
        let sans = ts.resolveCTFont(style: style, pixelScale: 2.0)
        let cap = Float(CTFontGetCapHeight(sans))
        let lhPx = style.resolvedLineHeight * 2.0
        let asc = Float(CTFontGetAscent(sans))
        let desc = Float(CTFontGetDescent(sans))
        let base = ((lhPx - (asc + desc)) * 0.5 + asc).rounded()
        #expect(m.y * 2.0 == (base - cap * 1.35).rounded())
        #expect((m.y + m.w) * 2.0 == (base + cap * 0.55).rounded())
    }

    // MARK: - #954: AppleFontSmoothing 0

    @Test("#954: AppleFontSmoothing reads a number or a string as its integer; only 0 turns smoothing off")
    func appleFontSmoothingPreference() {
        #expect(AppleFontSmoothingPreference.level(from: NSNumber(value: 0)) == 0)
        #expect(AppleFontSmoothingPreference.level(from: NSNumber(value: 2)) == 2)
        #expect(AppleFontSmoothingPreference.level(from: "0" as NSString) == 0)
        #expect(AppleFontSmoothingPreference.level(from: " 1 ") == 1)
        #expect(AppleFontSmoothingPreference.level(from: "smooth") == nil)
        #expect(AppleFontSmoothingPreference.level(from: nil) == nil)
        #expect(!AppleFontSmoothingPreference.allows(value: NSNumber(value: 0)))
        #expect(!AppleFontSmoothingPreference.allows(value: "0"))
        #expect(AppleFontSmoothingPreference.allows(value: NSNumber(value: 1)))
        #expect(AppleFontSmoothingPreference.allows(value: "x"))
        #expect(AppleFontSmoothingPreference.allows(value: nil))
        #if os(macOS)
        let raw = CFPreferencesCopyAppValue("AppleFontSmoothing" as CFString, kCFPreferencesCurrentApplication)
        #expect(AppleFontSmoothingPreference.smoothingAllowedByUser == AppleFontSmoothingPreference.allows(value: raw))
        #else
        #expect(AppleFontSmoothingPreference.smoothingAllowedByUser)
        #endif
    }

    @Test("#954: FontSmoothing.on draws as .off (unsmoothed pipeline) when the user turned smoothing off")
    func onFollowsUserSmoothing() {
        #expect(FontSmoothing.on.pipeline(smoothingAllowedByUser: true) == .smoothed)
        #expect(FontSmoothing.on.pipeline(smoothingAllowedByUser: false) == .unsmoothed)
        #expect(FontSmoothing.windfoil.pipeline(smoothingAllowedByUser: false) == .smoothed)
        #expect(FontSmoothing.windfoil.pipeline(smoothingAllowedByUser: true) == .smoothed)
        #expect(FontSmoothing.off.pipeline(smoothingAllowedByUser: true) == .unsmoothed)
        #expect(FontSmoothing.off.pipeline(smoothingAllowedByUser: false) == .unsmoothed)
        #expect(FontSmoothing.directWrite.pipeline(smoothingAllowedByUser: true) == .unsmoothed)
        #if os(macOS)
        #expect(FontSmoothing.systemDefault.pipeline(smoothingAllowedByUser: false) == .unsmoothed)
        #expect(FontSmoothing.systemDefault.pipeline(smoothingAllowedByUser: true) == .smoothed)
        #endif
        let allowed = AppleFontSmoothingPreference.smoothingAllowedByUser
        #expect(FontSmoothing.on.pipeline == (allowed ? .smoothed : .unsmoothed))
        let ts = TextSystem()
        ts.smoothing = .on
        #expect(ts.applePipeline == FontSmoothing.on.pipeline)
    }
}
