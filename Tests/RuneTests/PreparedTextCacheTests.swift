import RuneMotion
import Testing
@testable import Rune

@Suite("Prepared text layout cache")
struct PreparedTextCacheTests {
    private func layout(_ text: String, in system: TextSystem) -> TextLayoutBox {
        system.layoutKeyed(text: text, style: TextStyle(size: 16), maxWidth: 160,
                           pixelScale: 1, emitGlyphs: false)
    }

    @Test func changingRichKeyAttributesPreservesDictionaryLookup() {
        let style = TextStyle(size: 17)
        let shape = TextShapeKey(authText: "mix", spans: nil, pills: [], style: style,
                                 pixelScale: 2, fontEpoch: 1, languageTag: nil, maxWidth: 80)
        var changed = shape
        changed.spans = [TextSpan("mix", italic: true)]
        changed.style.size = 20
        let rebuilt = TextShapeKey(authText: "mix", spans: [TextSpan("mix", italic: true)], pills: [],
                                   style: TextStyle(size: 20), pixelScale: 2, fontEpoch: 1,
                                   languageTag: nil, maxWidth: 80)
        #expect(changed == rebuilt)
        #expect([changed: 1][rebuilt] == 1)
        #expect([shape: 1][rebuilt] == nil)
    }

    @Test func retainedLabelChecksRasterScaleAndAuthoredBytes() {
        let system = TextSystem()
        let value = "café"
        let label: El<Void> = text(value).font(TextStyle(size: 16, wrap: .noWrap))
        let original = ElDisplayResolver.resolveText(el: label, rawText: value, isSecure: false)
        let measured = system.layoutKeyed(text: value, style: original.style, maxWidth: nil, pixelScale: 2, emitGlyphs: false)
        let window = TextRasterWindow(lowerY: -1, upperY: 100)
        let promoted = original.retainedGlyphs(in: measured, using: system, maxWidth: nil, pixelScale: 2, window: window)
        let box = system.layoutKeyed(text: value, style: original.style, maxWidth: nil, pixelScale: 2, emitGlyphs: true)
        #expect(promoted?.glyphs == box.shaped.glyphs)
        #expect(!measured.hasGlyphs)
        #expect(original.retainedGlyphs(in: box, using: system, maxWidth: nil, pixelScale: 2, window: window) != nil)
        #expect(original.retainedGlyphs(in: box, using: system, maxWidth: nil, pixelScale: 1, window: window) == nil)
        let alternate = ElDisplayResolver.resolveText(el: label, rawText: "cafe\u{301}", isSecure: false)
        #expect(alternate.retainedGlyphs(in: box, using: system, maxWidth: nil, pixelScale: 2, window: window) == nil)
        _ = system.setLanguage(system.language == "ja" ? "ar" : "ja")
        #expect(original.retainedGlyphs(in: box, using: system, maxWidth: nil, pixelScale: 2, window: window) == nil)
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
    @Test func fillingMeasuredGlyphsPreservesBaselinesClustersAndMasks() throws {
        let system = TextSystem()
        let sample = "A fi e\u{301} 漢字\nA ثاني 🧩"
        let style = TextStyle(size: 16, wrap: .wrap)
        let width: Float = 85
        let measured = system.layoutKeyed(text: sample, style: style, maxWidth: width,
                                          pixelScale: 2, emitGlyphs: false)
        let direct = system.layoutKeyed(text: sample, style: style, maxWidth: width,
                                        pixelScale: 2, emitGlyphs: true, keep: .owned)
        let filled = system.layoutKeyed(text: sample, style: style, maxWidth: width,
                                        pixelScale: 2, emitGlyphs: true)
        #expect(filled.shaped.glyphs == direct.shaped.glyphs)
        #expect(filled.shaped.lineGlyphRanges == direct.shaped.lineGlyphRanges)
        #expect(filled.shaped.lineBaselinesPx == direct.shaped.lineBaselinesPx)
        let original = try #require(measured.shaped.lineStrings.first?.ctLine)
        let painted = try #require(filled.shaped.lineStrings.first?.ctLine)
        #expect(original === painted)
        #expect(!measured.hasGlyphs)
    }
    #endif

    @Test func budgetEvictsTheOldestPassAndItsReusableShape() {
        let system = TextSystem()
        let initial = system.layoutKeys()
        let oldest = layout("one", in: system).shapeKey
        #expect(system.keepPrepared(since: initial) == 1)
        let next = system.layoutKeys()
        let latest = layout("two", in: system).shapeKey
        // Upstream counts 2,048 bytes per layout and 64 bytes per UTF-8 byte.
        #expect(system.keepPrepared(since: next, budget: 2_048 + 3 * 64) == 1)
        #expect(system.layoutKeys() == [latest])
        let shaped = system.shapedCount
        #expect(layout("two", in: system).shapeKey == latest)
        #expect(system.shapedCount == shaped)
        #expect(layout("one", in: system).shapeKey == oldest)
        #expect(system.shapedCount == shaped + 1)
    }

    @Test func preparingAnotherWidthKeepsBothBreaksForMounting() {
        let system = TextSystem()
        let words = "A mounted view and a later view can use this text at two different widths."
        func atWidth(_ width: Float) -> TextLayoutBox {
            system.layoutKeyed(text: words, style: TextStyle(size: 16, wrap: .wrap), maxWidth: width,
                               pixelScale: 1, emitGlyphs: false)
        }
        let wide = atWidth(380)
        let lines = wide.shaped.lineCount
        #expect(system.prepareLayouts { _ = atWidth(90) } == 1)
        #expect(system.prepareLayouts { _ = atWidth(90) } == 0)
        let shaped = system.shapedCount
        let rebroken = system.rebrokenCount
        let narrow = atWidth(90)
        #expect(narrow !== wide)
        #expect(narrow.shaped.lineCount > lines)
        #expect(atWidth(380) === wide)
        #expect(wide.shaped.lineCount == lines)
        #expect(atWidth(90) === narrow)
        #expect(system.shapedCount == shaped)
        #expect(system.rebrokenCount == rebroken)
        withExtendedLifetime((wide, narrow)) {
            system.rest()
            #expect(system.cachedLayoutCount == 2)
        }
    }

    @Test func budgetProtectsOrdinaryAndExternallyHeldLayouts() {
        let system = TextSystem()
        let ordinary = layout("already cached", in: system).shapeKey
        let initial = system.layoutKeys()
        var held: TextLayoutBox? = layout("held by the mounted view", in: system)
        let heldKey = held!.shapeKey
        _ = layout("scratch only", in: system)
        withExtendedLifetime(held) {
            #expect(system.keepPrepared(since: initial, budget: 0) == 2)
            #expect(system.layoutKeys() == [ordinary, heldKey])
            system.rest()
            #expect(system.layoutKeys() == [ordinary, heldKey])
        }
        held = nil
        system.rest()
        #expect(system.layoutKeys() == [ordinary])
    }

    @Test func commitBudgetKeepsActiveWidthsAndEvictsOnlyStaleLayouts() throws {
        let system = TextSystem()
        let style = TextStyle(size: 16, wrap: .wrap)
        func width(_ width: Float) -> TextLayoutBox {
            system.layoutKeyed(text: "a label with two prepared widths", style: style, maxWidth: width,
                               pixelScale: 1, emitGlyphs: false)
        }
        let mounted = width(180)
        let old = system.layoutKeyed(text: "W", style: style, maxWidth: 100, pixelScale: 1, emitGlyphs: true)
        let glyph = try #require(old.shaped.glyphs.first)
        // Cross the cache budget without making the native shaper build a 3 MiB fixture.
        old.shaped.glyphs = Array(repeating: glyph, count: (3 << 20) / MemoryLayout<PositionedGlyph>.stride + 1)
        #expect(system.prepareLayouts { _ = width(35) } == 1)
        let alternate = width(35)
        let active: Set<TextShapeKey> = [mounted.shapeKey]
        for _ in 0..<59 { system.endCommit(activeKeys: active) }
        let recent = layout("recent", in: system)
        #expect(system.cachedLayoutBox(for: old.shapeKey) === old)
        system.endCommit(activeKeys: active)
        #expect(system.cachedLayoutBox(for: old.shapeKey) == nil)
        #expect(system.cachedLayoutBox(for: recent.shapeKey) === recent)
        #expect(system.cachedLayoutBox(for: mounted.shapeKey) === mounted)
        #expect(system.cachedLayoutBox(for: mounted.shapeKey, matchingWidth: 35) === alternate)
        #expect(alternate.lastUsedCommit == mounted.lastUsedCommit)
    }

    @Test func aPassOverBudgetReleasesItsLargestLooseLayoutFirst() {
        let system = TextSystem()
        let before = system.layoutKeys()
        _ = layout("a sizeable paragraph", in: system)
        let small = layout("hi", in: system).shapeKey
        let medium = layout("hello", in: system).shapeKey
        #expect(system.keepPrepared(since: before, budget: 2 * 2_048 + 7 * 64) == 3)
        #expect(system.layoutKeys() == [small, medium])
        #expect(system.keepPrepared(since: system.layoutKeys()) == 0)
    }

    @Test func speculativeElisionProbesLeaveNoUnbudgetedMeasureOrRunEntries() {
        let system = TextSystem()
        var clipped = TextStyle(size: 16)
        clipped.wrap = .ellipsis
        _ = system.measure("already displayed", style: clipped, maxWidth: 40, pixelScale: 1)
        let before = [system.cachedMeasureCount, system.cachedShapedTextCount,
                      system.cachedElisionCount, system.cachedTypesetterCount]
        _ = system.prepareLayouts {
            for index in 0..<12 {
                let value = "Hidden paragraph with several words \(index)"
                _ = system.measure(value, style: clipped, maxWidth: 40, pixelScale: 1)
                _ = system.shape(text: value, style: clipped, maxWidth: 40,
                                 pixelScale: 1, emitGlyphs: false)
            }
        }
        #expect([system.cachedMeasureCount, system.cachedShapedTextCount,
                 system.cachedElisionCount, system.cachedTypesetterCount] == before)
    }

    @Test func advanceInRunReusesItsPreparedClustersAtTheSameScale() throws {
        let system = TextSystem()
        let run = TextRun("AV e\u{301} אב")
        let style = TextStyle(size: 18)
        var cluster: TextRunCellLayout?
        #expect(system.prepareLayouts {
            cluster = system.cachedRunCellLayout(run, style: style, pixelScale: 2)
        } == 1)
        let prepared = try #require(cluster)
        #expect(system.cachedRunCellLayout(run, style: style, pixelScale: 2) === prepared)
        #expect(system.cachedRunCellLayout(run, style: style, pixelScale: 1) !== prepared)
        #expect(system.glyphAtlas.rasterized == 0)
        system.rest()
        #expect(system.cachedLayoutCount == 0)
        #expect(system.cachedRunCellLayout(run, style: style, pixelScale: 2) !== prepared)
    }

    @Test func preparedRunMountsWithTheSameGraphemeAdvancesAndFrame() throws {
        let run = TextRun("AVe\u{301}Z")
        let view: Runtime<Bool>.ViewFn = { _, _ in
            row().children([0, 1, 2, 5].map { byte in
                text("").key("cell-\(byte)").advanceIn(run, at: byte)
            })
        }
        let root: Runtime<Bool>.ViewFn = { opened, cx in opened ? view(opened, &cx) : el() }
        let size = Vec2(280, 80)
        let warm = Runtime(state: false, viewport: size, view: root)
        let cold = Runtime(state: false, viewport: size, view: root)
        _ = warm.frame(at: 0)
        _ = cold.frame(at: 0)
        let glyphs = warm.textSystem.glyphAtlas.rasterized
        #expect(warm.prepareText(view, size: size) > 0)
        #expect(warm.prepareText(view, size: size) == 0)
        #expect(warm.textSystem.glyphAtlas.rasterized == glyphs)
        let shaped = warm.textSystem.shapedCount
        warm.update(at: 0.1) { state, _ in state = true }
        cold.update(at: 0.1) { state, _ in state = true }
        #expect(warm.frame(at: 0.1).primitives == cold.frame(at: 0.1).primitives)
        for byte in [0, 1, 2, 5] {
            let warmed = try #require(warm.element(byKey: "cell-\(byte)"))
            let direct = try #require(cold.element(byKey: "cell-\(byte)"))
            #expect(warmed.rect == direct.rect)
        }
        #expect(warm.textSystem.shapedCount == shaped)
    }
}
