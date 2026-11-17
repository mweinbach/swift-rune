import Foundation
import Testing
import RuneRef
#if canImport(CoreText)
import CoreText
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import Rune

@Suite("Text/Edit/Input/A11y/Clipboard/Image #958 Parity")
struct TextAudit958ParityTests {
    // MARK: - Helpers

    private static func makeMinimalValidPNG(width: Int, height: Int) throws -> [UInt8] {
        let pixels = [UInt8](repeating: 255, count: width * height * 4)
        let frame = Frame(width: width, height: height, rgba: pixels)
        return [UInt8](try frame.pngData())
    }

    // MARK: - Wave A: glyphsIn & ParsedShortcut.fromPhysicalKey / physicalKey / requireModifier

    @Test("Wave A (text/run.rs): TextSystem.glyphsIn returns cluster glyphs at UTF-8 boundaries and empty inside")
    func glyphsInRunLayoutAndNonBoundary() {
        let ts = TextSystem()
        let style = TextStyle(size: 14, family: .systemUI)
        let run = TextRun("a\u{0301}b") // "a\u{0301}" = 3 UTF-8 bytes, "b" = byte 3
        let layout = ts.runLayout(run, style: style, scale: 2.0)

        let firstCluster = ts.glyphsIn(run: layout, at: 0, scale: 2.0, origin: Vec2(10, 20))
        #expect(!firstCluster.isEmpty)
        let combiningInterior = ts.glyphsIn(run: layout, at: 1, scale: 2.0, origin: Vec2(10, 20))
        #expect(combiningInterior.isEmpty)
        let secondCluster = ts.glyphsIn(run: layout, at: 3, scale: 2.0, origin: Vec2(10, 20))
        #expect(!secondCluster.isEmpty)

        let shifted = ts.glyphsIn(run: layout, at: 0, scale: 2.0, origin: Vec2(30, 40))
        #expect(!shifted.isEmpty)
        #expect(abs(shifted[0].rect.x - firstCluster[0].rect.x - 20.0) < 0.01)
        #expect(abs(shifted[0].rect.y - firstCluster[0].rect.y - 20.0) < 0.01)
    }

    @Test("Wave A (shortcuts/keys.rs): ParsedShortcut.fromPhysicalKey, physicalKey, and requireModifier")
    func parsedShortcutPhysicalKeyAndRequireModifier() throws {
        let cmdK = try ParsedShortcut.fromPhysicalKey(.keyK, mods: Mods(cmd: true), platform: .mac)
        #expect(cmdK.physicalKey == .keyK)
        #expect(cmdK.description == "super+k")
        try cmdK.requireModifier(on: .mac)

        let f5 = try ParsedShortcut.parseOn("f5", platform: .mac)
        try f5.requireModifier(on: .mac)

        let bareA = try ParsedShortcut.fromPhysicalKey(.keyA, mods: .none, platform: .mac)
        #expect(bareA.physicalKey == .keyA)
        #expect(throws: ShortcutError.self) {
            try bareA.requireModifier(on: .mac)
        }
    }

    // MARK: - L723, L727, L729: CoreText Advances, Carets, and Default Smoothing / ApplePipeline

    #if canImport(CoreText) && canImport(CoreGraphics)
    @Test("L723 & L727 (core_text_tests.rs:107,:241): advances and carets follow CoreText across scales")
    func coreTextAdvancesAndCaretsAcrossScales() {
        let ts = TextSystem()
        let scales: [Float] = [1.0, 1.5, 2.0, 3.0]
        let sizes: [Float] = [11, 13, 14, 18]
        let sample = "Hello, world! AV To Wa"

        for sz in sizes {
            for s in scales {
                let style = TextStyle(size: sz, family: .systemUI)
                let shaped = ts.shape(text: sample, style: style, maxWidth: nil, pixelScale: s, emitGlyphs: true)
                #expect(!shaped.glyphs.isEmpty)
                let baseMeasure = ts.measure(sample, style: style, maxWidth: nil, pixelScale: 1.0)
                #expect(abs(shaped.size.x - baseMeasure.x) < 1.0, "size=\(sz) scale=\(s): \(shaped.size.x) vs \(baseMeasure.x)")
            }
        }

        // L727: Caret X strictly increases at UTF-8 grapheme cluster boundaries across scales
        let clusterText = "a\u{0301}b🙂c"
        let boundaries = [0, 3, 4, 8, 9]
        for s: Float in [1.0, 2.0] {
            let shaped = ts.shape(text: clusterText, style: TextStyle(size: 15, family: .systemUI), maxWidth: nil, pixelScale: s, emitGlyphs: true)
            let xs = boundaries.map { ts.caretRect(in: shaped, utf8Offset: $0, pixelScale: s).x }
            for i in 1..<xs.count {
                #expect(xs[i] > xs[i - 1], "scale=\(s) boundary \(boundaries[i - 1])->\(boundaries[i]): \(xs)")
            }
            #expect(abs(xs.last! - shaped.size.x) < 1.0)
        }
    }

    @Test("L729 (coretext_match_tests.rs:6): TextSystem default smoothing, applePipeline, and smoothed vs off masks")
    func textSystemDefaultSmoothingAndApplePipeline() {
        let ts = TextSystem()
        #if os(macOS)
        #expect(ts.smoothing == .on)
        #expect(ts.applePipeline == .smoothed)
        #else
        #expect(ts.smoothing == .windfoilChromium)
        #endif

        let style = TextStyle(size: 14, family: .systemUI)
        let onShaped = ts.shape(text: "Rg", style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: true)

        ts.smoothing = .off
        #expect(ts.applePipeline == .unsmoothed)
        let offShaped = ts.shape(text: "Rg", style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: true)

        #expect(onShaped.glyphs.count == offShaped.glyphs.count)
        #expect(!onShaped.glyphs.isEmpty)
        #if os(macOS)
        #expect(onShaped.glyphs[0].uv != offShaped.glyphs[0].uv || onShaped.glyphs[0].rect != offShaped.glyphs[0].rect)
        #endif
    }
    #endif

    // MARK: - L738 & L748: DefaultFonts & Language lists

    @Test("L738 & L748 (default_fonts_tests.rs:50 & language.rs:194): DefaultFonts & HK/Windows/Linux fallbacks")
    func defaultFontsAndLanguageFallbackCompleteness() {
        #expect(DefaultFonts.registerIfNeeded())
        #expect(!DefaultFonts.sansFamily.isEmpty)
        #expect(!DefaultFonts.monoFamily.isEmpty)
        for name in DefaultFonts.bundledFontNames {
            #expect(DefaultFonts.fontURL(named: name) != nil, "missing bundled font \(name)")
        }

        // L748: hongKongChinese + preferred/excluded lists + [nil, "Yu Gothic"] ordering
        #expect(TextWriting.hongKongChinese.bcp47Tag == "zh-HK")
        #expect(TextLanguageRegistry.parseWriting(from: "zh-HK")?.writing == .hongKongChinese)
        #expect(TextWriting.japanese.excludedFamilies.contains(" GB"))
        #expect(TextWriting.japanese.preferredFamilies.contains("Yu Gothic"))
        #expect(TextLanguageRegistry.fallbackOrder(names: ["PingFang KR", "Malgun Gothic"], writing: .korean) == [1, 0])
        #expect(TextLanguageRegistry.fallbackOrder(names: ["Arial", "Noto Sans CJK SC"], writing: .simplifiedChinese) == [1, 0])
        let nilOrder = TextLanguageRegistry.fallbackOrder(names: [nil, "Yu Gothic"], writing: .japanese)
        #expect(nilOrder == [1, 0])
    }

    // MARK: - L742 & L787: Atlas Eviction Replay + Atlas Burst Resets & IconQuad

    #if canImport(CoreText) && canImport(CoreGraphics)
    @Test("L742 (glyph_cache_tests.rs:65): Replay re-populates glyphs after GlyphAtlas.evictPage")
    func replayFollowsAtlasEviction() {
        let atlas = GlyphAtlas(width: 64, height: 64)
        let ts = TextSystem(glyphAtlas: atlas)
        let style = TextStyle(size: 16, family: .systemUI)

        let s1 = ts.shape(text: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: true)
        #expect(s1.glyphs.contains { $0.atlasPage >= 1 }, "expected overflow beyond page 0 in 64x64 atlas")

        let countBefore = s1.glyphs.count
        atlas.evictPage(0)
        ts.clearLayoutCaches()

        let s2 = ts.shape(text: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", style: style, maxWidth: nil, pixelScale: 1.0, emitGlyphs: true)
        #expect(s2.glyphs.count == countBefore)
        for q in s2.glyphs {
            #expect(q.rect.z > 0 && q.rect.w > 0)
            #expect(q.uv.z > q.uv.x && q.uv.w > q.uv.y)
        }
    }

    @Test("L770 & L787 (quality_tests.rs:4,:455): Tight advances, burst resets == 0, and TextSystem.iconQuad")
    func qualityTightAdvancesBurstResetsAndIconQuad() {
        let atlas = GlyphAtlas(width: 64, height: 64)
        let ts = TextSystem(glyphAtlas: atlas)
        let style = TextStyle(size: 13, family: .systemUI)

        // L787: burst across multiple characters/sizes overflows onto pages without resetting
        for sz: Float in [12, 16, 20] {
            _ = ts.shape(text: "ABCDEFGHIJKLM", style: TextStyle(size: sz, family: .systemUI), maxWidth: nil, pixelScale: 1.0, emitGlyphs: true)
        }
        #expect(atlas.resets == 0)

        // L787: iconQuad validity & invalid-size guard
        let star = SVGIcon(viewBox: 24, paths: ["M12 2 L20 20 L4 20 Z"])
        let quad = ts.iconQuad(star, pixelSize: 16, origin: SIMD2<Float>(5, 9))
        #expect(quad != nil)
        if let q = quad {
            #expect(q.rect.x == 5 && q.rect.y == 9)
            #expect(q.rect.z == 16 && q.rect.w == 16)
            #expect(q.uv.z > q.uv.x && q.uv.w > q.uv.y)
        }
        #expect(ts.iconQuad(star, pixelSize: 0) == nil)
        #expect(ts.iconQuad(star, pixelSize: -4) == nil)
        #expect(ts.iconQuad(star, pixelSize: .nan) == nil)
        let defaultTs = TextSystem()
        let beforeIcons = defaultTs.glyphAtlas.cachedIconCount
        #expect(defaultTs.iconQuad(star, pixelSize: Float(GlyphAtlas.atlasSize)) == nil)
        #expect(defaultTs.iconQuad(star, pixelSize: Float(GlyphAtlas.atlasSize - 1)) == nil)
        #expect(defaultTs.glyphAtlas.cachedIconCount == beforeIcons)
        #expect(defaultTs.iconQuad(star, pixelSize: 24) != nil)

        // L742: TextSystem.smoothing resolves FontSmoothing.systemDefault in both runLayout and shape
        let tsOff = TextSystem()
        tsOff.smoothing = .off
        let rlDefault = tsOff.runLayout(TextRun("Hi"), style: TextStyle(size: 14, fontSmoothing: .systemDefault), scale: 1.0)
        #expect(rlDefault.cellLayout?.style.fontSmoothing == .off)
        let offGlyphs = tsOff.glyphsIn(run: rlDefault, at: 0, scale: 1.0)
        #expect(!offGlyphs.isEmpty)
        let tsOffExplicit = TextSystem()
        let rlExplicit = tsOffExplicit.runLayout(TextRun("Hi"), style: TextStyle(size: 14, fontSmoothing: .off), scale: 1.0)
        let explicitGlyphs = tsOffExplicit.glyphsIn(run: rlExplicit, at: 0, scale: 1.0)
        #expect(offGlyphs.map(\.uv) == explicitGlyphs.map(\.uv))

        // L770: first glyph baseline origin alignment & distinct shape outputs across different styles
        let a = ts.shape(text: "Hello", style: style, maxWidth: nil, pixelScale: 2.0, emitGlyphs: true)
        let b = ts.shape(text: "Hello", style: TextStyle(size: 18, family: .systemUI), maxWidth: nil, pixelScale: 2.0, emitGlyphs: true)
        #expect(!a.glyphs.isEmpty && !b.glyphs.isEmpty)
        #expect(a.glyphs[0].rect.x >= 0 && a.glyphs[0].rect.x < 4.0)
        #expect(a.size != b.size)
        #expect(a.glyphs != b.glyphs)
    }

    @Test("Retained glyphs follow smoothing changes and preserve a label's explicit override")
    func retainedGlyphSmoothingChanges() throws {
        func makeRuntime() -> Runtime<Void> {
            Runtime(state: (), viewport: Vec2(160, 72), pixelScale: 1) { _, _ in
                col().sizeFull().center().bg(.black)
                    .child(text("Lights on").font(Tok.Typography.title).w(79.5).color(.white))
                    .child(text("Explicit").font(TextStyle(size: 13, fontSmoothing: .off)).w(79.5).color(.white))
            }
        }

        let runtime = makeRuntime()
        let modes: [FontSmoothing] = [.on, .windfoilChromium, .off, .windfoilChromium]
        for (step, mode) in modes.enumerated() {
            let time = Double(step)
            runtime.fontSmoothing = mode
            let scene = runtime.frame(at: time)
            for (label, expected) in [("Lights on", mode), ("Explicit", .off)] {
                let layout = try #require(runtime.nodeTextLayouts.values.first { $0.box.authText == label }?.box)
                let pens = layout.shaped.glyphPens
                try #require(!pens.isEmpty)
                #expect(pens.allSatisfy { $0.smoothing == expected })
            }
            let cached = runtime.textSystem.glyphCache.flattened
            #expect(cached > 0)
            #expect(runtime.frame(at: time).primitives == scene.primitives)
            #expect(runtime.textSystem.glyphCache.flattened == cached)

            let fresh = makeRuntime()
            fresh.fontSmoothing = mode
            let actual = try RuneRef.render(scene)
            let expected = try RuneRef.render(fresh.frame(at: time))
            #expect(actual == expected)
        }
    }

    // MARK: - L756 & L759: CoreGraphics vs Analytic Outline Mask & Corpus Sweep

    @Test("L756 & L759 (smoothing_tests.rs:223,:315): CG vs analytic outline masks and smoothing polarity sweep")
    func coreGraphicsAndAnalyticSmoothingMaskParity() throws {
        let runFullCorpus = ProcessInfo.processInfo.environment["RUNE_MACOS_SMOOTHING_CORPUS"] != nil
        let sizes: [Float] = runFullCorpus ? [8, 9, 10, 12, 14, 16, 20, 24] : [8, 12, 16]

        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 16.0, nil)
        var ch: UniChar = 0x49 // 'I'
        var glyph: CGGlyph = 0
        #expect(CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1))
        let cmds = OutlineBuilder.commands(font: font, glyph: glyph)
        #expect(!cmds.isEmpty)
        let built = try #require(OutlineBuilder.build(commands: cmds, unit: 1.0, upem: Float(CTFontGetUnitsPerEm(font))))
        let store = OutlineStore()
        let key = OutlineStore.Key(font: 1, glyph: UInt32(glyph), hinted: OutlineHinting.none.key())
        guard case .outline(let entry) = store.glyph(key, build: { built }) else {
            Issue.record("expected outline entry")
            return
        }
        let scale = Float(16.0) / Float(max(1, CTFontGetUnitsPerEm(font)))
        let fill = OutlineFillParams(record: entry.record, scale: scale, radius: 0, pen: SIMD2<Float>(4.0, 20.0))
        let mask = OutlineMaskFiller.fillMask(store: store, fill: fill, atX: 0, atY: 0, width: 16, height: 24)
        #expect(mask.contains { $0 > 200 })
        #expect(mask.contains(0))

        // Compare CoreGraphics smoothed vs unsmoothed rendering + coverageExponent polarity across sizes
        let cmp = PixelCompareHarness()
        let darkOnLight = PixelComparePair(name: "light", fg: "#1d1e22", bg: "#ffffff")
        let whiteOnDark = PixelComparePair(name: "dark", fg: "#ffffff", bg: "#1d1e22")
        for sz in sizes {
            let c = PixelCompareCase(
                name: "s\(Int(sz))",
                family: .systemUI,
                weight: 400,
                size: sz,
                lineHeight: sz * 1.25,
                wrap: nil,
                text: "IeoS",
                origin: .zero,
                region: SIMD4<Float>(0, 0, 80, 40),
                wholeRegion: true
            )
            let cgOnLight = cmp.renderCoreTextReference(pair: darkOnLight, scale: 1.0, reference: .smoothed, cases: [c], size: SIMD2<Float>(80, 40))
            let cgOffLight = cmp.renderCoreTextReference(pair: darkOnLight, scale: 1.0, reference: .unsmoothed, cases: [c], size: SIMD2<Float>(80, 40))
            #expect(cgOnLight.rgb != cgOffLight.rgb, "smoothed vs unsmoothed CG output should differ at size \(sz)")
            _ = cmp.renderCoreTextReference(pair: whiteOnDark, scale: 1.0, reference: .smoothed, cases: [c], size: SIMD2<Float>(80, 40))

            let darkExp = TextCoreTextMatch.coverageExponent(mode: .windfoilChromium, fill: [0.11, 0.12, 0.13, 1.0], apple: true, windows: false)
            let lightExp = TextCoreTextMatch.coverageExponent(mode: .windfoilChromium, fill: [1, 1, 1, 1], apple: true, windows: false)
            #expect(darkExp > lightExp)
        }
    }

    // MARK: - L792: Rewrap reuses cached CTTypesetter without reshaping

    @Test("L792 (rewrap_tests.rs:83): changing maxWidth or alignment rebreaks without rebuilding typesetter")
    func rewrapReusesTypesetterWithoutReshaping() {
        let ts = TextSystem()
        let text = "The quick brown fox jumps over the lazy dog across wrapped lines"

        let wide = ts.shape(text: text, style: TextStyle(size: 14, align: .leading, wrap: .wrap), maxWidth: 260, pixelScale: 1.0, emitGlyphs: true)
        #expect(ts.shapedBuildCount == 1)
        #expect(ts.rebrokenCount == 0)

        let narrow = ts.shape(text: text, style: TextStyle(size: 14, align: .leading, wrap: .wrap), maxWidth: 95, pixelScale: 1.0, emitGlyphs: true)
        #expect(narrow.lineCount > wide.lineCount)
        #expect(ts.shapedBuildCount == 1)
        #expect(ts.rebrokenCount == 1)

        let centered = ts.shape(text: text, style: TextStyle(size: 14, align: .center, wrap: .wrap), maxWidth: 95, pixelScale: 1.0, emitGlyphs: true)
        #expect(centered.lineCount == narrow.lineCount)
        #expect(ts.shapedBuildCount == 1)
        #expect(ts.rebrokenCount == 2)

        ts.clearLayoutCaches()
        _ = ts.shape(text: text, style: TextStyle(size: 14, align: .leading, wrap: .wrap), maxWidth: 95, pixelScale: 1.0, emitGlyphs: false)
        #expect(ts.shapedBuildCount == 2)
    }

    #endif

    // MARK: - L811: Monospace 4-col tab stops, mono span tabs, and proportional tabs

    #if canImport(CoreText) || os(Linux) || os(Windows) || os(Android) || RUNE_BROWSER_TEXT
    @Test("L811 (text/tests.rs:89): mono tabs fill 4-col stops, mono spans reset per line, proportional tab == 1 space")
    func monoAndProportionalTabStops() {
        let ts = TextSystem()
        let mono = TextStyle(size: 14, family: .monospace)

        let tab1 = ts.measure("\t", style: mono, maxWidth: nil, pixelScale: 1.0).x
        let spaces4 = ts.measure("    ", style: mono, maxWidth: nil, pixelScale: 1.0).x
        #expect(abs(tab1 - spaces4) < 0.25)

        let aTabB = ts.measure("a\tb", style: mono, maxWidth: nil, pixelScale: 1.0).x
        let a3SpacesB = ts.measure("a   b", style: mono, maxWidth: nil, pixelScale: 1.0).x
        #expect(abs(aTabB - a3SpacesB) < 0.25)

        let abcdTabE = ts.measure("abcd\te", style: mono, maxWidth: nil, pixelScale: 1.0).x
        let abcd4SpacesE = ts.measure("abcd    e", style: mono, maxWidth: nil, pixelScale: 1.0).x
        #expect(abs(abcdTabE - abcd4SpacesE) < 0.25)

        let multi = ts.measure("ab\nc\td", style: mono, maxWidth: nil, pixelScale: 1.0).x
        let multiRef = ts.measure("ab\nc   d", style: mono, maxWidth: nil, pixelScale: 1.0).x
        #expect(abs(multi - multiRef) < 0.25)

        // Monospace TextSpan inside proportional text expands to 4-col stops counted from span start and resets on \n
        let sans = TextStyle(size: 14, family: .systemUI)
        let spanShaped = ts.shape(
            text: "",
            spans: [TextSpan("px "), TextSpan("a\tb\nc\td", monospace: true)],
            style: sans,
            maxWidth: nil,
            pixelScale: 1.0,
            emitGlyphs: false
        )
        let spanRef = ts.shape(
            text: "",
            spans: [TextSpan("px "), TextSpan("a   b\nc   d", monospace: true)],
            style: sans,
            maxWidth: nil,
            pixelScale: 1.0,
            emitGlyphs: false
        )
        #expect(abs(spanShaped.size.x - spanRef.size.x) < 0.25)

        // Proportional text treats \t as 1 space advance
        let propTab = ts.measure("a\tb", style: sans, maxWidth: nil, pixelScale: 1.0).x
        let propSpace = ts.measure("a b", style: sans, maxWidth: nil, pixelScale: 1.0).x
        #expect(abs(propTab - propSpace) < 0.25)

        for tracking: Float in [-0.75, 1.5] {
            let style = TextStyle(size: 14, letterSpacing: tracking, family: .monospace)
            let tab = ts.measure("e\u{301}\tA", style: style, maxWidth: nil, pixelScale: 2).x
            let spaces = ts.measure("e\u{301}  A", style: style, maxWidth: nil, pixelScale: 2).x
            #expect(abs(tab - spaces) < 0.25)
        }
        let tabbed = ts.shape(text: "é\tA", style: mono, maxWidth: nil, pixelScale: 2)
        let expanded = ts.shape(text: "é   A", style: mono, maxWidth: nil, pixelScale: 2)
        let afterTab = "é\t".utf8.count
        let caret = ts.caretRect(in: tabbed, utf8Offset: afterTab, pixelScale: 2)
        let target = ts.caretRect(in: expanded, utf8Offset: "é   ".utf8.count, pixelScale: 2)
        #expect(abs(caret.x - target.x) < 0.25)
        #expect(ts.hitTestUTF8Offset(in: tabbed, localX: caret.x, localY: caret.y, pixelScale: 2) == afterTab)
    }
    #endif

    // MARK: - L827: Trak optical size (56, 14, true)

    @Test("L827 (trak.rs:124): Trak optical-size spacing at pixelSize=56 pointSize=14 enabled=true")
    func trakExplicitOpticalSize56_14() {
        let t = Trak(
            sizes: [
                .init(pointSize: 12, units: 0),
                .init(pointSize: 14, units: -22),
                .init(pointSize: 28, units: 28),
                .init(pointSize: 36, units: 21),
            ],
            unitsPerEm: 2048
        )
        let expected = (-22.0 - 21.0) * Float(56.0) / 2048.0
        #expect(abs(t.spacing(pixelSize: 56, pointSize: 14, enabled: true) - expected) < 1e-5)
    }

    // MARK: - L830, L832, L844, L851, L865, L886: TextEdit Security, Plain vs Rich, Differential Spans, Pills, Blocks

    @Test("L830 (history_tests.rs:4): disabling isSecure inside an open undoGroup resumes recording")
    func disablingSecureInsideOpenUndoGroupResumesRecording() {
        var ed = TextEdit()
        ed.undoGroup { ed in
            ed.insert("secret")
            ed.isSecure = true
            ed.insert("!")
            ed.isSecure = false
            ed.insert("ok")
        }

        #expect(ed.text == "secret!ok")
        let didUndo = ed.undo()
        #expect(didUndo)
        #expect(ed.text == "secret!")
        let didUndoAgain = ed.undo()
        #expect(!didUndoAgain)
    }

    @Test("L832 (rich_tests.rs:2): plain TextEdit ignores rich marks, Shift+Enter softBreaks, and pasteHTML formatting")
    func plainEditIgnoresRichFormatting() {
        var ed = TextEdit("hello", multiline: true)
        #expect(!ed.isRichEnabled)

        ed.selectAll()
        ed.toggleMark(.bold)
        #expect(ed.richMarks.isEmpty)

        ed.setCursor(utf8Offset: 5)
        _ = ed.handleKey(KeyEvent(key: .enter, mods: Mods(shift: true)))
        #expect(ed.text == "hello\n")
        #expect(ed.softBreaks.isEmpty)

        ed.pasteHTML("<b>world</b>", plain: "world")
        #expect(ed.text == "hello\nworld")
        #expect(ed.richMarks.isEmpty)
    }

    @Test("L844 (rich_tests.rs:344): overlapping rich marks later-wins + 300-run seeded differential test")
    func richMarkOverlapsAndDifferentialModel() {
        var ed = TextEdit("0123456789").rich(true)
        ed.setSelectionRaw(anchor: 2, cursor: 5)
        ed.setMark(.link("https://first.test"))
        ed.setSelectionRaw(anchor: 0, cursor: 10)
        ed.setMark(.link("https://second.test"))
        let links = ed.richMarks.filter { if case .link = $0.mark { return true }; return false }
        #expect(links.count == 1)
        #expect(links[0] == RichMarkRange(start: 0, end: 10, mark: .link("https://second.test")))

        struct PRNG {
            var state: UInt64
            mutating func next() -> Int {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Int((state >> 32) & 0x7FFF_FFFF)
            }
        }
        var rng = PRNG(state: 0xDEADBEEF_12345678)
        let pool: [RichMark] = [.bold, .italic, .underline, .strike, .code]
        for _ in 0..<300 {
            let n = 12
            var model = [[Bool]](repeating: [Bool](repeating: false, count: pool.count), count: n)
            var rich = TextEdit(String(repeating: "a", count: n)).rich(true)
            for _ in 0..<8 {
                let a = rng.next() % n
                let b = rng.next() % (n + 1)
                let lo = min(a, b)
                let hi = max(a, b)
                guard hi > lo else { continue }
                let mIdx = rng.next() % pool.count
                let setOp = (rng.next() % 2) == 0
                rich.setSelectionRaw(anchor: lo, cursor: hi)
                if setOp {
                    rich.setMark(pool[mIdx])
                    for p in lo..<hi { model[p][mIdx] = true }
                } else {
                    rich.removeMark(pool[mIdx])
                    for p in lo..<hi { model[p][mIdx] = false }
                }
            }
            for p in 0..<n {
                for (mIdx, mark) in pool.enumerated() {
                    let actual = rich.richMarks.contains { $0.mark == mark && $0.start <= p && p < $0.end }
                    #expect(actual == model[p][mIdx])
                }
            }
        }
    }

    @Test("L851 (rich_tests.rs:656): pill midpoint snap (right half -> end) and internal caret insert recovery")
    func pillMidpointSnapAndInternalCaretRecovery() {
        var ed = TextEdit("hi ").rich(true)
        ed.setCursor(utf8Offset: 3)
        ed.insertPill(id: "u1", label: "@alice") // range 3..<9, midpoint = 6
        ed.insert("!")
        let pill = ed.pills.first!
        #expect(pill.range == 3..<9)

        // Left half (< midpoint) snaps to start (3); right half (>= midpoint) snaps to end (9)
        ed.setCursor(utf8Offset: 4)
        #expect(ed.cursor == 3)
        ed.setCursor(utf8Offset: 7)
        #expect(ed.cursor == 9)

        // Forcing caret inside pill via setSelectionRaw then inserting "Z" steps caret out after pill, preserving pill (`rich_tests.rs:676-680`)
        ed.setSelectionRaw(anchor: 5, cursor: 5)
        ed.insert("Z")
        #expect(ed.text == "hi @aliceZ!")
        #expect(ed.pills.count == 1)
        #expect(ed.pills.first?.range == 3..<9)
    }

    @Test("L865 (edit/tests.rs:28): multi-byte grapheme offsets, secure Debug redaction, and clear keeps isSecure")
    func editMultibyteIndicesDebugNonLeakAndClearSecure() {
        var ed = TextEdit("h\u{00E9}\u{1F642}") // h (1) + é (2) + 🙂 (4) = 7 UTF-8 bytes
        #expect(ed.text.utf8.count == 7)
        ed.setCursor(utf8Offset: 7)
        _ = ed.handleKey(KeyEvent(key: .arrowLeft))
        #expect(ed.cursor == 3)
        _ = ed.handleKey(KeyEvent(key: .arrowLeft))
        #expect(ed.cursor == 1)

        ed.setText("s3cr3t", recordUndo: false)
        ed.isSecure = true
        #expect(!String(reflecting: ed).contains("s3cr3t"))
        ed.isRevealed = true
        #expect(!String(reflecting: ed).contains("s3cr3t"))
        ed.clear()
        #expect(ed.text.isEmpty)
        #expect(ed.isSecure)
    }

    @Test("L886 (edit/tests.rs:719): rich blocks Enter->bullet, Shift+Enter soft break, empty exit, numbered, outdent, code")
    func richBlockEnterSoftBreakNumberedOutdentAndCode() {
        var ed = TextEdit("first", multiline: true).rich(true)
        ed.setCursor(utf8Offset: 5)
        ed.setBlock(.bullet(0))
        _ = ed.handleKey(KeyEvent(key: .enter))
        #expect(ed.blocks == [.bullet(0), .bullet(0)])

        // Tab indents to Bullet(1), Shift+Enter creates soft break preserving Bullet(1) at line 2
        _ = ed.handleKey(KeyEvent(key: .tab))
        #expect(ed.blocks == [.bullet(0), .bullet(1)])
        ed.insert("nested")
        _ = ed.handleKey(KeyEvent(key: .enter, mods: Mods(shift: true)))
        ed.insert("cont")
        #expect(ed.softBreaks == [2])
        #expect(ed.blocks == [.bullet(0), .bullet(1), .bullet(1)])

        // Enter after "cont" makes an empty Bullet(1) line; next Enter unwraps empty Bullet(1) to .paragraph
        _ = ed.handleKey(KeyEvent(key: .enter))
        #expect(ed.blocks.last == .bullet(1))
        _ = ed.handleKey(KeyEvent(key: .enter))
        #expect(ed.blocks.last == .paragraph)

        // Numbered(1) + Backspace outdents to Numbered(0), then Backspace exits to .paragraph (`edit/tests.rs:754-758`)
        ed.setBlock(.numbered(1))
        _ = ed.handleKey(KeyEvent(key: .backspace))
        #expect(ed.blocks.last == .numbered(0))
        _ = ed.handleKey(KeyEvent(key: .backspace))
        #expect(ed.blocks.last == .paragraph)

        // Code block ignores inline marks, keeps .code on Enter, and inserts '\t' on Tab
        ed.setBlock(.code)
        ed.toggleMark(.bold)
        #expect(ed.richMarks.isEmpty)
        _ = ed.handleKey(KeyEvent(key: .tab))
        ed.insert("let x = 1")
        _ = ed.handleKey(KeyEvent(key: .enter))
        ed.insert("let y = 2")
        #expect(ed.blocks.last == .code)
        #expect(ed.text.hasSuffix("\tlet x = 1\nlet y = 2"))
    }

    // MARK: - L893 & L900: CursorImage Validation + Runtime Hit/Inherit/Drag/Release

    @Test("L893 & L900 (cursor/image_tests.rs:13,:120): Cursor.image in Runtime and PNG/hotspot/size errors")
    func cursorImageRuntimeAndValidationParity() throws {
        let validPNG = try Self.makeMinimalValidPNG(width: 16, height: 16)
        #expect(!validPNG.isEmpty)

        let ci = CursorImage(png: validPNG, hot: SIMD2<Float>(4, 6))
        let rt = Runtime(state: 0, viewport: Vec2(200, 200), pixelScale: 1) { (_: Int, _) -> El<Int> in
            col()
                .cursor(.grab)
                .child(col().key("canvas").w(80).h(80).cursor(.image(ci)).onClick { _, _ in })
                .child(spacer())
        }
        _ = rt.frame(at: 0)

        rt.pointerMove(to: Vec2(20, 20), at: 1)
        #expect(rt.currentCursor() == .image(ci))
        rt.pointerDown(at: Vec2(20, 20), at: 2)
        rt.pointerMove(to: Vec2(150, 150), at: 3)
        #expect(rt.currentCursor() == .image(ci))
        rt.pointerUp(at: Vec2(150, 150), at: 4)
        #expect(rt.currentCursor() == .grab)

        // L900: NaN / Infinity clamped; odd (5,5) rounds up (`image_tests.rs:124`); oversized (300,8), invalid/truncated PNG fail
        let nanHot = try CursorImage(png: validPNG, hot: SIMD2<Float>(.nan, .infinity)).decodedMetrics()
        #expect(nanHot.hot.x == 0 && nanHot.hot.y == 7)

        let oddPNG = try Self.makeMinimalValidPNG(width: 5, height: 5)
        let oddCss = try CursorImage(png: oddPNG, hot: SIMD2<Float>(9, 9)).cssCursor(url: "blob:x")
        #expect(oddCss == "image-set(url(\"blob:x\") 2x) 2 2, auto")

        let bigPNG = try Self.makeMinimalValidPNG(width: 300, height: 8)
        #expect(throws: CursorImageError.invalidDimensions(width: 300, height: 8, maxSide: 256)) {
            _ = try CursorImage(png: bigPNG, hot: .zero).decodedMetrics()
        }

        let truncated = Array(validPNG.prefix(16))
        #expect(throws: CursorImageError.notPNG) {
            _ = try CursorImage(png: truncated, hot: .zero).decodedMetrics()
        }
    }

    // MARK: - L907: KeyDiagnostics nested inner child repair, determinism, and clean empty diff

    @Test("L907 (key_diagnostics.rs:240): nested child repair, 2nd-build determinism, and clean repair is empty")
    func keyDiagnosticsNestedDeterminismAndClean() {
        let tree: El<Int> = col()
            .key("outer")
            .child(
                col().key("inner")
                    .child(text("x").key("dup"))
                    .child(text("y").key("dup"))
            )
        let (repaired1, fixes1) = KeyDiagnostics.repair(tree)
        #expect(!fixes1.isEmpty)
        #expect(KeyDiagnostics.clean(repaired1))
        let (repaired2, fixes2) = KeyDiagnostics.repair(tree)
        #expect(fixes1.count == fixes2.count)
        #expect(repaired1.children[0].children[1].keyId == repaired2.children[0].children[1].keyId)

        let cleanTree: El<Int> = col().key("root").child(text("a").key("k1")).child(text("b").key("k2"))
        let (_, cleanFixes) = KeyDiagnostics.repair(cleanTree)
        #expect(cleanFixes.isEmpty)
    }

    @Test("Deep duplicate-key diagnostics retain preorder warnings and repaired mounted paths")
    func deepDuplicateKeyDiagnostics() {
        var tree: El<Void> = col().key("group")
            .child(col().key("row").child(el().key("x")).child(el().key("x")))
            .child(col().key("row").child(el().key("y")).child(el().key("y")))
            .child(el().key("row#dup1"))
        let levels = (0..<96).map { "level-\($0)" }
        for level in levels { tree = col().key(level).child(tree) }

        let result = KeyDiagnostics.find(in: tree)
        let group = (levels.reversed() + ["group"]).joined(separator: "/")
        #expect(result.map(\.key) == ["row", "x", "y"])
        #expect(result.map(\.paths) == [
            ["\(group)/row#0", "\(group)/row#1"],
            ["\(group)/row/x#0", "\(group)/row/x#1"],
            ["\(group)/row/y#0", "\(group)/row/y#1"]
        ])

        var renamed: [String] = []
        let repaired = KeyDiagnostics.repair(tree, at: "/@mounted") { renamed.append($0.path) }
        let directory = (["@mounted"] + levels.dropLast().reversed().map { "@\($0)" } + ["@group"])
            .joined(separator: "/")
        #expect(renamed == [
            "/\(directory)/@row#dup2",
            "/\(directory)/@row/@x#dup1",
            "/\(directory)/@row#dup2/@y#dup1"
        ])
        #expect(KeyDiagnostics.clean(repaired.tree))
        #expect(!KeyDiagnostics.clean(tree))
    }

    // MARK: - L921 & L928: MacOSCarbonKeyMap Fn-drop masks & ShortcutEngine bare chord guard

    @Test("L921 & L928 (shortcuts/macos.rs:223 & service.rs:431): macOS NSEvent masks & bare chord refusal")
    func macosModifiersFnDropAndShortcutEngineBareChordGuard() throws {
        #expect(MacOSCarbonKeyMap.carbonModifiers(fromNSEventFlags: 1_835_008) == (MacOSCarbonKeyMap.controlMask | MacOSCarbonKeyMap.optionMask | MacOSCarbonKeyMap.cmdMask))
        #expect(MacOSCarbonKeyMap.carbonModifiers(fromNSEventFlags: 1_179_648) == (MacOSCarbonKeyMap.shiftMask | MacOSCarbonKeyMap.cmdMask))
        #expect(MacOSCarbonKeyMap.carbonModifiers(fromNSEventFlags: 8_650_752) == MacOSCarbonKeyMap.controlMask)
        #expect(MacOSCarbonKeyMap.carbonModifiers(fromNSEventFlags: 786_432) == (MacOSCarbonKeyMap.controlMask | MacOSCarbonKeyMap.optionMask))
        if let parsed = MacOSCarbonKeyMap.parseRemap(enabled: true, keycode: 40, flags: 8_650_752), let inner = parsed {
            #expect(inner.mods == MacOSCarbonKeyMap.controlMask)
        } else {
            Issue.record("expected parsed remap dropping Fn bit")
        }

        let engine = ShortcutEngine(title: "Test", bindings: .virtual([:]), claims: ShortcutProcessClaims())
        let bare = try ParsedShortcut.parseOn("k", platform: .mac)
        switch engine.register(id: 1, shortcut: bare) {
        case .failure(.unmodifiedDisallowed): break
        default: Issue.record("expected unmodifiedDisallowed failure")
        }
        #expect((try? engine.register(id: 2, shortcut: try .parseOn("f5", platform: .mac)).get()) != nil)
        #expect((try? engine.register(id: 3, shortcut: try .parseOn("cmd+k", platform: .mac)).get()) != nil)

        engine.allowUnmodified = true
        #expect((try? engine.register(id: 4, shortcut: bare).get()) != nil)
    }

    // MARK: - L963, L984, L1012: SecretClipboard unwritten clear, unreadable wipe timeout, 6-event permutation walk

    @Test("L963 & L984 & L1012 (clipboard.rs:566, hold_tests.rs:159, secret_tests.rs:723)")
    func secretClipboardUnwrittenClearUnreadableTimeoutAndSixEventWalk() {
        let host = MemorySecretClipboardHost()
        let unwrittenSlot = SecretSlot()
        let unwrittenHold = SecretClipboardHold(slot: unwrittenSlot)
        #expect(!unwrittenHold.clearNow())
        _ = host.submitSecret("never", slot: unwrittenSlot, clearAfterSeconds: 30, now: 0)
        #expect(unwrittenSlot.state == .cleared)

        let droppedSlot = SecretSlot()
        droppedSlot.settleDroppedUnwritten()
        #expect(droppedSlot.state == .replaced)

        let slot = SecretSlot()
        let _ = host.submitSecret("pw", slot: slot, clearAfterSeconds: 30, now: 10)
        host.setFailNextWrite("denied 1")
        _ = host.submitSecret("pw", slot: slot, clearAfterSeconds: 30, now: 12)
        #expect(slot.state == .failed("denied 1"))
        #expect(host.isWatching)

        host.setUnreadable(true)
        _ = slot.cancelAndRequestClear()
        host.requestClear(slot: slot)
        host.tick(now: 15)
        #expect(host.isWatching)
        #expect(host.rawPlainText == "pw")
        #expect(host.wipeAttempts == 0)

        host.setUnreadable(false)
        host.tick(now: 40)
        #expect(host.rawPlainText == nil)
        #expect(slot.state == .cleared)
        #expect(host.wipeAttempts == 1)

        // L1012: Exhaustive 6-event permutation walk (720 walks) across SecretMachine state machine
        let events: [SecretMachineEvent] = [
            .held,
            .cancel,
            .report(.failed("err")),
            .released(.said(.cleared)),
            .released(.said(.replaced)),
            .dropped,
        ]
        func permute(_ k: Int, _ arr: inout [SecretMachineEvent], _ visit: ([SecretMachineEvent]) -> Void) {
            if k == arr.count {
                visit(arr)
                return
            }
            for i in k..<arr.count {
                arr.swapAt(k, i)
                permute(k + 1, &arr, visit)
                arr.swapAt(k, i)
            }
        }
        var copy = events
        var walkCount = 0
        permute(0, &copy) { seq in
            walkCount += 1
            var machine = SecretMachine.default
            for ev in seq {
                let effects = stepSecret(&machine, event: ev)
                if effects.contains(.clear) {
                    #expect(machine.isCancelled)
                }
            }
        }
        #expect(walkCount == 720)
    }

    // MARK: - L1017 & L1026: A11y Roles Completeness & Virtual List setSize / positionInSet

    @Test("L1017 & L1026 (a11y/roles.rs:170 & a11y/tests.rs:214): role mappings and virtual list setSize/positionInSet")
    func a11yRolesAndVirtualListPositions() {
        #if os(macOS)
        #expect(AppKitAccessibilityMapper.nsRole(for: .button) == .button)
        #expect(AppKitAccessibilityMapper.nsRole(for: .switchControl) == .checkBox)
        #expect(AppKitAccessibilityMapper.nsRole(for: .option) == .menuItem)
        #expect(AppKitAccessibilityMapper.nsRole(for: .progress) == .progressIndicator)
        #expect(AppKitAccessibilityMapper.nsRole(for: .tabList) == .tabGroup)
        #expect(AppKitAccessibilityMapper.nsRole(for: .passwordInput) == .textField)
        #endif

        let roleRt = Runtime(state: 0, viewport: Vec2(240, 120), pixelScale: 1) { (_: Int, _) -> El<Int> in
            col()
                .child(text("OK").key("ok").role(.button).defaultButton(true))
                .child(text("Inert").key("inert").inert(true))
                .child(text("Hidden").key("hidden").a11yHidden())
        }
        _ = roleRt.frame(at: 0)
        let roleSnap = roleRt.accessibilitySnapshot()
        #expect(roleSnap.children.map(\.id) == ["ok", "inert"])
        #expect(roleSnap.children.first?.role == ElementRole.button)
        #expect(roleSnap.children.last?.isDisabled == true)

        let vRt = Runtime(state: 0, viewport: Vec2(200, 120), pixelScale: 1) { (_: Int, _) -> El<Int> in
            let list: El<Int> = col()
                .key("list")
                .size(200, 120)
                .role(.list)
                .scrollY()
                .virtualRows(count: 20, estimatedRowHeight: 30, key: { _, i in "row-\(i)" }) { _, i in
                    text("Row \(i)").role(.listItem).h(30)
                }
            return list
        }
        _ = vRt.frame(at: 0)
        let vSnap = vRt.accessibilitySnapshot()
        func findList(_ node: AccessibilityNode) -> AccessibilityNode? {
            if node.role == .list { return node }
            for c in node.children {
                if let hit = findList(c) { return hit }
            }
            return nil
        }
        if let listNode = findList(vSnap) {
            #expect(listNode.sizeOfSet == 20)
            #expect(!listNode.children.isEmpty)
            for (idx, c) in listNode.children.enumerated() {
                #expect(!c.id.contains("__v_top_spacer") && !c.id.contains("__v_bot_spacer"))
                #expect(c.sizeOfSet == 20)
                #expect(c.positionInSet == idx)
            }
            let dumpJson = AccessibilityDump.jsonString(from: vSnap)
            #expect(dumpJson.contains("\"setSize\" : 20") || dumpJson.contains("\"setSize\":20"))
            #expect(dumpJson.contains("\"position\" : 1") || dumpJson.contains("\"position\":1"))
        } else {
            Issue.record("Expected virtual list AccessibilityNode")
        }
    }

    // MARK: - L1049: ImageFromURL MAX_SIDE+1 rejection & 2-level mip chain

    @Test("L1049 (from_url_tests.rs:5): IMAGE_MAX_SIDE+1 fails and 2x2 RGBA builds 2 mip levels")
    func imageMaxSidePlusOneAndMipLevels() {
        let tooWide = Int(IMAGE_MAX_SIDE) + 1
        let fail = ImageCache.land(url: "mem://oversized", fetched: .rgba(width: UInt32(tooWide), height: 1, data: Data()), pixelSize: 1)
        switch fail {
        case .failure: break
        case .success: Issue.record("Expected oversized image failure")
        }

        let mips = DecodedImage.generateMipChain(width: 2, height: 2, rgba: Data(repeating: 0xAA, count: 16))
        #expect(mips.count == 2)
    }
}
