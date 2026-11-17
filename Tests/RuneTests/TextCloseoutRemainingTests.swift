import Foundation
import Testing
@testable import Rune

@Suite("Text Closeout Remaining Parity (Language, Trak, Cursor, Metrics, Input, Image, Spell, A11y)")
struct TextCloseoutRemainingTests {

    @Test func imageIDsUseTheSameSHA256OnEveryPlatform() {
        let vectors = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
            (String(repeating: "a", count: 64),
             "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
        ]
        for (message, hex) in vectors {
            let data = Data(message.utf8)
            let bytes = ImageContentDigest.sha256(data)
            #expect(bytes.map { String(format: "%02x", $0) }.joined() == hex)
            #expect(ImageId.contentHash(data).bytes == bytes)
        }
    }

    // MARK: - text/language.rs (2 Rust tests)

    @Test
    func fallbackOrderFollowsTheLanguage() {
        let fonts: [String?] = ["PingFang SC", "Apple SD Gothic Neo", "Hiragino Sans GB", "Hiragino Sans"]
        let ja = TextLanguageRegistry.fallbackOrder(names: fonts, writing: .japanese)
        #expect(fonts[ja[0]] == "Hiragino Sans")
        #expect(ja[1..<4].allSatisfy { $0 != 3 })

        let sc = TextLanguageRegistry.fallbackOrder(names: fonts, writing: .simplifiedChinese)
        #expect(fonts[sc[0]] == "PingFang SC")
        #expect(fonts[sc[1]] == "Hiragino Sans GB")

        let ko = TextLanguageRegistry.fallbackOrder(names: fonts, writing: .korean)
        #expect(fonts[ko[0]] == "Apple SD Gothic Neo")

        #expect(TextLanguageRegistry.writingOfText("こんにちは") == .japanese)
        #expect(TextLanguageRegistry.writingOfText("안녕하세요") == .korean)
        #expect(TextLanguageRegistry.writingOfText("\u{A960}\u{D7B0}") == .korean)
        #expect(TextLanguageRegistry.writingOfText("中文汉字") == .simplifiedChinese)
        #expect(TextLanguageRegistry.writingOfText("\u{20000}") == .simplifiedChinese)
        #expect(TextLanguageRegistry.writingOfText("ㄅㄆㄇ") == .traditionalChinese)
        #expect(TextLanguageRegistry.writingOfText("hello") == nil)

        #expect(TextLanguageRegistry.effectiveLanguageTag(for: "ㄅㄆㄇ", chosen: "en-US") == "zh-Hant")
        #expect(TextLanguageRegistry.effectiveLanguageTag(for: "中文", chosen: "zh-TW") == "zh-Hant")
        #expect(TextLanguageRegistry.effectiveLanguageTag(for: "中文", chosen: "en-US") == "zh-Hans")
        #expect(TextLanguageRegistry.effectiveLanguageTag(for: "こんにちは", chosen: "zh-CN") == "ja")
        #expect(TextLanguageRegistry.effectiveLanguageTag(for: "hello", chosen: "fr-FR") == "fr-FR")
    }

    @Test
    func textSystemCanSwitchAndClearLanguage() {
        let fresh = TextSystem()
        #expect(fresh.setLanguage("ja,en-US") == true)
        #expect(fresh.language == "ja")
        #expect(fresh.setLanguage("ja") == false)
        #expect(fresh.setLanguage("ko") == true)
        #expect(fresh.language == "ko")
        #expect(fresh.setLanguage("") == false)
        #expect(fresh.language == "ko")
        #expect(fresh.setLanguage(nil) == true)
        #expect(fresh.language == nil)
        #expect(fresh.setLanguage(nil) == false)
    }

    // MARK: - text/trak.rs (3 Rust tests)

    private func makeSyntheticTrak(tracks: [(Float, [Int16])], sizes: [Float]) -> Data {
        var d = Data([0, 1, 0, 0, 0, 0, 0, 12, 0, 0, 0, 0])
        let sizeTableOffset = 12 + 8 + tracks.count * 8
        let valuesOffset = sizeTableOffset + sizes.count * 4
        func appendU16(_ v: UInt16) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        }
        func appendI16(_ v: Int16) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        }
        func appendU32(_ v: UInt32) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        }
        func appendFixed(_ f: Float) {
            var be = Int32(f * 65536.0).bigEndian
            withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        }
        appendU16(UInt16(tracks.count))
        appendU16(UInt16(sizes.count))
        appendU32(UInt32(sizeTableOffset))
        for (i, tr) in tracks.enumerated() {
            appendFixed(tr.0)
            appendU16(0)
            appendU16(UInt16(valuesOffset + i * sizes.count * 2))
        }
        for s in sizes { appendFixed(s) }
        for (_, vals) in tracks {
            for v in vals { appendI16(v) }
        }
        return d
    }

    @Test
    func trakSpacingMovesTrackingFromPixelSizeToPointSize() {
        let t = Trak(
            sizes: [
                .init(pointSize: 12, units: 0),
                .init(pointSize: 13, units: -12),
                .init(pointSize: 14, units: -22),
                .init(pointSize: 24, units: 6),
                .init(pointSize: 28, units: 28),
                .init(pointSize: 32, units: 26),
                .init(pointSize: 36, units: 21),
            ],
            unitsPerEm: 2048
        )
        #expect(abs(t.spacing(pixelSize: 28, pointSize: 14, enabled: true) - (-22 - 28) * 28.0 / 2048.0) < 1e-5)
        #expect(t.spacing(pixelSize: 14, pointSize: 14, enabled: true) == 0)
        #expect(abs(t.spacing(pixelSize: 14, pointSize: 14, enabled: false) - 22.0 * 14.0 / 2048.0) < 1e-5)
        #expect(abs(t.spacing(pixelSize: 33, pointSize: 33, enabled: true) - (24.0 - 25.0) * 33.0 / 2048.0) < 1e-5)
        #expect(t.units(at: 8) == 0)
        #expect(t.units(at: 500) == 21)
    }

    @Test
    func trakParseReadsTrackZeroOrInterpolatesAroundIt() {
        let sizes: [Float] = [12, 24]
        let t1 = Trak.parse(makeSyntheticTrak(tracks: [(-1.0, [-40, -20]), (0.0, [0, 10]), (1.0, [40, 20])], sizes: sizes), unitsPerEm: 2048)
        #expect(t1?.sizes == [.init(pointSize: 12, units: 0), .init(pointSize: 24, units: 10)])

        let t2 = Trak.parse(makeSyntheticTrak(tracks: [(-1.0, [-40, -20]), (1.0, [40, 60])], sizes: sizes), unitsPerEm: 2048)
        #expect(t2?.sizes == [.init(pointSize: 12, units: 0), .init(pointSize: 24, units: 20)])

        let t3 = Trak.parse(makeSyntheticTrak(tracks: [(0.5, [8, 16])], sizes: sizes), unitsPerEm: 2048)
        #expect(t3?.sizes == [.init(pointSize: 12, units: 8), .init(pointSize: 24, units: 16)])
    }

    @Test
    func trakMalformedTablesTrackNothingWithoutPanicking() {
        let good = makeSyntheticTrak(tracks: [(-1.0, [-40, -20]), (0.0, [0, 10]), (1.0, [40, 20])], sizes: [12, 24])
        #expect(Trak.parse(good, unitsPerEm: 0) == nil)
        for len in 0..<good.count {
            if let t = Trak.parse(good.prefix(len), unitsPerEm: 2048) {
                #expect(t.spacing(pixelSize: 28, pointSize: 14, enabled: true).isFinite)
            }
        }
        var hugeOffsets = good
        hugeOffsets[6] = 0xff; hugeOffsets[7] = 0xff
        #expect(Trak.parse(hugeOffsets, unitsPerEm: 2048) == nil)

        var hugeSizeTable = good
        hugeSizeTable[16] = 0xff; hugeSizeTable[17] = 0xff; hugeSizeTable[18] = 0xff; hugeSizeTable[19] = 0xff
        #expect(Trak.parse(hugeSizeTable, unitsPerEm: 2048) == nil)

        var hugeCounts = good
        hugeCounts[12] = 0xff; hugeCounts[13] = 0xff; hugeCounts[14] = 0xff; hugeCounts[15] = 0xff
        #expect(Trak.parse(hugeCounts, unitsPerEm: 2048) == nil)

        // Track 0 points out of bounds -> 0 tracking
        var badValues = good
        let horiz = 12
        let track0OffsetPos = horiz + 8 + 1 * 8 + 6
        badValues[track0OffsetPos] = 0xff; badValues[track0OffsetPos + 1] = 0xff
        let tBadVal = Trak.parse(badValues, unitsPerEm: 2048)
        #expect(tBadVal?.sizes.allSatisfy { $0.units == 0 } == true)
        #expect(tBadVal?.spacing(pixelSize: 28, pointSize: 14, enabled: true) == 0)

        // Unused track (+1.0) points out of bounds -> track 0 preserved
        var badUnused = good
        let unusedOffsetPos = horiz + 8 + 2 * 8 + 6
        badUnused[unusedOffsetPos] = 0xff; badUnused[unusedOffsetPos + 1] = 0xff
        let tBadUnused = Trak.parse(badUnused, unitsPerEm: 2048)
        #expect(tBadUnused?.sizes == [.init(pointSize: 12, units: 0), .init(pointSize: 24, units: 10)])

        for i in 0..<good.count {
            var corrupted = good
            corrupted[i] = 0xff
            if let t = Trak.parse(corrupted, unitsPerEm: 2048) {
                #expect(t.spacing(pixelSize: 28, pointSize: 14, enabled: true).isFinite)
            }
        }
    }

    // MARK: - text/cursor.rs (visual moveLine, lineEdge, soft-wrap TextAffinity)

    @Test
    func cursorVisualMoveLineLineEdgeAndAffinityAtSoftWrap() throws {
        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400, wrap: .wrap)
        let text = "Hello wonderful world of wrapping text"
        let shaped = ts.shape(text: text, spans: nil, style: style, maxWidth: 110, pixelScale: 1.0, emitGlyphs: false)
        #expect(shaped.lineCount >= 2)

        let line0End = shaped.textTestLines[0].utf8Start + shaped.textTestLines[0].text.utf8.count
        if shaped.textTestLines.count >= 2 && shaped.textTestLines[1].utf8Start == line0End {
            let upRect = ts.caretRect(in: shaped, utf8Offset: line0End, affinity: .upstream, pixelScale: 1.0)
            let downRect = ts.caretRect(in: shaped, utf8Offset: line0End, affinity: .downstream, pixelScale: 1.0)
            #expect(upRect.y < downRect.y)
            #expect(downRect.x <= upRect.x)
        }

        // Visual move down then up preserves goalX
        let down = try #require(ts.moveLine(in: shaped, utf8Offset: 4, delta: 1, pixelScale: 1.0))
        #expect(down.utf8Offset > 4)
        let backUp = try #require(ts.moveLine(in: shaped, utf8Offset: down.utf8Offset, delta: -1, goalX: down.goalX, affinity: down.affinity, pixelScale: 1.0))
        #expect(backUp.utf8Offset <= line0End)

        // First line moving up clamps to start (0); past last line moving down returns nil (`cursor.rs:206-207`)
        #expect(ts.moveLine(in: shaped, utf8Offset: 4, delta: -1, pixelScale: 1.0)?.utf8Offset == 0)
        #expect(ts.moveLine(in: shaped, utf8Offset: text.utf8.count, delta: 1, pixelScale: 1.0) == nil)

        let home = ts.lineEdge(in: shaped, utf8Offset: down.utf8Offset, toEnd: false, affinity: down.affinity)
        let end = ts.lineEdge(in: shaped, utf8Offset: down.utf8Offset, toEnd: true, affinity: down.affinity)
        #expect(end.utf8Offset >= home.utf8Offset)

        // Explicit newline: lineEdge(toEnd: true) steps before '\n'
        let nlShaped = ts.shape(text: "abc\ndef", spans: nil, style: style, maxWidth: 400, pixelScale: 1.0, emitGlyphs: false)
        let nlEnd = ts.lineEdge(in: nlShaped, utf8Offset: 1, toEnd: true, affinity: .downstream)
        #expect(nlEnd.utf8Offset == 3)
    }

    // MARK: - text/line_metrics, underline, ltr_units, run, coretext_match, measure, icon

    @Test
    func lineMetricsUnderlinesLtrUnitsRunLayoutAndCoreTextMatch() {
        let style = TextStyle(size: 13, weight: 400)
        #expect(TextLineMetrics.specHeight(layoutHeightPx: 10, style: style, scale: 1.0, exact: true) == 16.25)
        #expect(TextLineMetrics.layoutHeight(layoutHeightPx: 10, style: style, scale: 1.0) == 17)
        #expect(TextLineMetrics.lastLineFill(lineAdvancePx: 60, hangingAdvancePx: 10, widthPx: 100) == 0.5)

        let edges = TextDecorations.underlineEdges(lineEndPx: 80.0, originX: 10.0, startX: 0.4, endX: 79.995)
        #expect(edges.0 == 10.0 && edges.1 == 90.0)

        let merged = TextDecorations.mergedPaddedBackgrounds([
            (SIMD4<Float>(10, 0, 20, 16), .white),
            (SIMD4<Float>(30, 0, 15, 16), .white),
        ], padding: 2)
        #expect(merged.count == 1)
        #expect(TextDecorations.spanRadius == 4.0)

        let units = TextBidiUnits.ltrUnits(in: "ملف (.gitignore) و renderView() هنا")
        #expect(units.count == 2)

        #expect(TextCoreTextMatch.quantisationSteps(ppem: 6.0) == 5.0)
        #expect(TextCoreTextMatch.quantisationSteps(ppem: 16.5) == 3.0)
        #expect(TextCoreTextMatch.quantisationSteps(ppem: 40.0) == 1.0)
        #expect(TextCoreTextMatch.glyphX(10.5, ppem: 26.0) == (10.0, 30))
        #expect(TextCoreTextMatch.glyphX(353.0 - 1.0 / 256.0, ppem: 40.0) == (352.0, 0))
        #expect(TextCoreTextMatch.browserDefault(platform: "MacIntel", touchPoints: 0) == .on)
        #expect(TextCoreTextMatch.browserDefault(platform: "MacIntel", touchPoints: 5) == .off)
        #expect(TextCoreTextMatch.coverageExponent(mode: .off, fill: [1, 1, 1, 1], apple: true, windows: false) == 1.0)
        #expect(TextCoreTextMatch.coverageExponent(mode: .off, fill: [0, 0, 0, 1], apple: false, windows: false) == 1.02)
        #expect(abs(TextCoreTextMatch.coverageExponent(mode: .off, fill: [1, 1, 1, 1], apple: false, windows: false) - 0.83) < 1e-6)
        #expect(abs(TextCoreTextMatch.coverageExponent(mode: .off, fill: [0.25, 0.25, 0.25, 0.5], apple: false, windows: false) - 0.925) < 1e-6)
        #expect(abs(TextCoreTextMatch.coverageExponent(mode: .off, fill: [1, 1, 1, 1], apple: false, windows: true) - 0.45) < 1e-6)
        #expect(TextCoreTextMatch.coverageExponent(mode: .off, fill: [0, 0, 0, 1], apple: false, windows: true) == 1.12)
        #expect(TextCoreTextMatch.coverageExponent(mode: .directWrite, fill: [0, 0, 0, 1], apple: false, windows: true) == 1.0)
        #expect(TextCoreTextMatch.coverageExponent(mode: .windfoilChromium, fill: [0, 0, 0, 1], apple: true, windows: false) > 1.0)
        #expect(FontSmoothing.all.count == 10)
        #expect(FontSmoothing.on.pipeline == .smoothed)
        #expect(FontSmoothing.off.pipeline == .unsmoothed)
        #expect(FontSmoothing.on.support() == .yes)
        #expect(FontSmoothing.windfoilRgb.support() == .yes)
        #expect(FontSmoothing.windfoilRgb.isLCD && FontSmoothing.windfoilRgb.drawn(lcdOK: false) == .windfoilChromium)
        #expect(FontSmoothing.clearType.drawn(lcdOK: false) == .directWrite)
        #expect({
            if case .no = FontSmoothing.slug.support(outlinesAvailable: false) { return true }
            return false
        }())
        #expect({
            if case .fallback = FontSmoothing.windfoilRgb.support(dualSourceSupported: false) { return true }
            return false
        }())
        #expect({
            if case .no = FontSmoothing.directWrite.support(isWindows: false) { return true }
            return false
        }())

        let ts = TextSystem()
        let run = TextRun("Hello")
        let rl = ts.runLayout(run, style: style, scale: 2.0)
        #expect(rl.x(atUTF8Offset: 0) == 0)
        #expect((rl.advance(atUTF8Offset: 0) ?? 0) > 0)

        let widths = TextMeasure.contentWidths("Hello world", style: style)
        #expect(widths.min <= widths.max)
        #expect(TextMeasure.advance("Hello", style: style) > 0)

        let orig = SVGIcon(viewBox: 16, paths: ["M2 2 L14 14"])
        let alt = SVGIcon(viewBox: 16, paths: ["M0 0 H16 V16 H0 Z"], strokeWidth: nil)
        IconSwapRegistry.setIconSwap { $0 == orig ? alt : nil }
        IconSwapRegistry.setIconSwapSize { $0 + 2 }
        defer {
            IconSwapRegistry.setIconSwap(nil)
            IconSwapRegistry.setIconSwapSize(nil)
        }
        #expect(IconSwapRegistry.resolvedIcon(for: orig).wasSwapped)
        #expect(IconSwapRegistry.resolvedSize(for: orig, requestedSize: 14) == 16)
        let cov = IconSwapRegistry.iconCoverageAt(icon: orig, pixelSize: 16)
        #expect(cov.count == 256 && cov.contains { $0 > 0 })
    }

    // MARK: - input/time.rs (3 tests) & input/keycaps.rs (5 tests) & input/secure_input.rs (2 tests)

    @Test
    func inputTimeAndKeycapsAndSecureClaim() {
        InputTime.scope(at: 42.5) {
            #expect(InputTime.current() == 42.5)
            #expect(InputTime.lastInput() == 42.5)
        }
        #expect(InputTime.sinceBoot(now: 100.0, uptime: 120.0, timestamp: 115.0) == 95.0)

        #expect(Keycaps.holdSeconds == 1.5)
        #expect(Keycaps.burstGapSeconds == 1.0)
        var kc = Keycaps()
        for (i, ch) in "Hi there".enumerated() {
            kc.key(at: 0.1 * Double(i), event: KeyEvent(key: .text(String(ch)), mods: Mods()))
        }
        #expect(kc.visible(at: 0.8).map(\.label) == ["Hi there"])
        kc.key(at: 0.9, event: KeyEvent(key: .command("k"), mods: Mods(cmd: true)))
        kc.key(at: 1.0, event: KeyEvent(key: .text("x"), mods: Mods()))
        let expectedCmd = Keycaps.modGlyphs(Mods(cmd: true)) + "K"
        #expect(kc.visible(at: 1.0).map(\.label) == ["Hi there", expectedCmd, "x"])
        kc.key(at: 2.3, event: KeyEvent(key: .text("y"), mods: Mods()))
        #expect(kc.visible(at: 2.3).map(\.label) == [expectedCmd, "x", "y"])
        #expect(kc.visible(at: 4.2).isEmpty)

        var k2 = Keycaps()
        for i in 0..<3 {
            k2.key(at: 0.2 * Double(i), event: KeyEvent(key: .arrowDown, mods: Mods()))
        }
        k2.key(at: 0.6, event: KeyEvent(key: .tab, mods: Mods(shift: true)))
        k2.key(at: 0.7, event: KeyEvent(key: .text(" "), mods: Mods(shift: true, ctrl: true, alt: true, cmd: true, logo: true)))
        k2.key(at: 0.8, event: KeyEvent(key: .modifier(.shiftLeft, pressed: false), mods: Mods()))
        #expect(k2.visible(at: 0.8).map(\.label) == ["↓ ×3", "⇧⇥", "⌃⌥⇧⌘␣"])

        var kSpace = Keycaps()
        for i in 0..<3 {
            kSpace.key(at: 0.1 * Double(i), event: KeyEvent(key: .text(" "), mods: Mods()))
        }
        #expect(kSpace.visible(at: 0.3).map(\.label) == ["␣␣␣"])

        var kLong = Keycaps()
        for (i, ch) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            kLong.key(at: 0.05 * Double(i), event: KeyEvent(key: .text(String(ch)), mods: Mods()))
        }
        #expect(kLong.visible(at: 1.3).map(\.label) == ["…defghijklmnopqrstuvwxyz"])
        #expect(Keycaps.titleCase("ı") == "ı" && Keycaps.titleCase("ß") == "ß" && Keycaps.titleCase("capslock") == "Capslock")
        #expect(KeycapsCorner.parse("top-right") == .topRight)
        #expect(KeycapsCorner.parse("middle") == nil)
        #expect(Keycaps.parseTheme("auto") == .some(nil))
        #expect(Keycaps.parseTheme("dark") == .some(true))
        #expect(Keycaps.parseTheme("blue") == nil)

        let claim = SecureInputClaim(touchOS: false)
        claim.set(true)
        #expect(claim.isActive == true)
        claim.windowFocus(false)
        #expect(claim.isActive == false)
    }

    // MARK: - image/pixels.rs, from_url.rs, animated loopCount, spell languages, a11y link/tree/dump

    @Test
    func pixelsAtlasUrlSetLoopBoundSpellAndA11yDiffDump() {
        let p = Pixels()
        p.setSourceURL("https://example.com/a.png")
        p.setSourceSet("a.png 100w, b.png 200w")
        p.set(width: 4, height: 4, rgba: Array(repeating: 255, count: 64))
        var atlas = ImageAtlas()
        let first = atlas.place(p, drawnSize: SIMD2<Float>(4, 4))
        #expect(first != nil && first?.page == 0 && atlas.copies == 1)
        let second = atlas.place(p, drawnSize: SIMD2<Float>(4, 4))
        #expect(second == first && atlas.copies == 1)
        atlas.endFrame()
        #expect(atlas.pages.count == 1)
        atlas.invalidate()
        #expect(atlas.pages[0].dirty == 0..<IMAGE_ATLAS_SIZE)

        let sel = ImageURLSet.select(
            sources: [.init(url: "1x.png", widthPixels: 100), .init(url: "2x.png", widthPixels: 200)],
            sizePt: 80,
            scale: 2.0
        )
        #expect(sel?.selected.url == "2x.png")

        let anim = DecodedImage(
            id: "a",
            width: 2,
            height: 2,
            mips: [],
            frames: [
                AnimatedImageFrame(width: 2, height: 2, rgba: Data(count: 16), durationSeconds: 0.1),
                AnimatedImageFrame(width: 2, height: 2, rgba: Data(repeating: 1, count: 16), durationSeconds: 0.1),
            ],
            loopCount: 1
        )
        #expect(anim.frameStoppingAfterLoops(at: 0.25)?.rgba == anim.frames.last?.rgba)

        let spell = SpellChecker(backend: CustomDictionarySpellChecker())
        spell.setAvailableLanguages(["en-US", "fr-FR"])
        spell.setLanguages(["de-DE", "fr-FR"])
        #expect(spell.languages() == ["fr-FR"])
        #expect(spell.availableLanguages() == ["en-US", "fr-FR"])

        let link = AccessibilityLink()
        let root = AccessibilityNode(
            id: "root",
            role: .group,
            label: "Window",
            isFocused: true,
            isFocusable: true,
            children: [
                AccessibilityNode(
                    id: "pw",
                    role: .textInput,
                    label: "Password",
                    value: "hunter2",
                    placeholder: "Enter password",
                    isFocusable: true,
                    isDisabled: true,
                    isReadOnly: true,
                    isInvalid: true,
                    characterCount: 7,
                    isSecure: true
                ),
                AccessibilityNode(
                    id: "txt",
                    role: .text,
                    value: "Static label"
                ),
                AccessibilityNode(
                    id: "btn",
                    role: .button,
                    selectedState: false,
                    toggled: .mixed,
                    liveRegion: .polite,
                    clipsChildren: true,
                    children: [
                        AccessibilityNode(id: "btn-lbl", role: .text, value: "Save Now")
                    ]
                ),
                AccessibilityNode(
                    id: "hdr",
                    role: .heading,
                    label: "Title",
                    range: A11yRange(value: 5, min: 0, max: 10, step: nil),
                    level: 0,
                    positionInSet: 0,
                    sizeOfSet: 3
                ),
            ]
        )
        #expect(link.service(rootNode: root, windowTitle: "Window") == nil)
        link.activate()
        let full = link.service(rootNode: root, windowTitle: "Window")
        #expect(full?.isFullTree == true && full?.updatedNodes.count == 6)
        #expect(link.service(rootNode: root, windowTitle: "Window") == nil)

        let rootDict = AccessibilityDump.dictionary(from: root, isRoot: true)
        #expect(rootDict["states"] == nil) // Root never gets "focused"; "focusable" is never emitted.

        let children = rootDict["children"] as? [[String: Any]] ?? []
        #expect(children.count == 4)
        let pwDict = children[0]
        #expect(pwDict["value"] == nil)
        #expect(pwDict["placeholder"] as? String == "Enter password")
        #expect(pwDict["chars"] as? Int == 7)
        let pwStates = pwDict["states"] as? [String] ?? []
        #expect(pwStates == ["disabled", "read-only", "invalid"])

        let txtDict = children[1]
        #expect(txtDict["name"] as? String == "Static label")
        #expect(txtDict["value"] == nil)

        let btnDict = children[2]
        #expect(btnDict["name"] as? String == "Save Now")
        let btnStates = btnDict["states"] as? [String] ?? []
        #expect(btnStates == ["mixed", "unselected", "live-polite", "clips"])

        let hdrDict = children[3]
        #expect(hdrDict["level"] as? Int == 1)
        #expect(hdrDict["position"] as? Int == 1)
        #expect(hdrDict["setSize"] as? Int == 3)

        let dump = AccessibilityDump.jsonString(from: root)
        #expect(!dump.contains("hunter2"))
    }
}
