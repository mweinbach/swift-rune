import Foundation
import Testing
@testable import Rune

@Suite("Text Closeout Parity (Ink, MaskCache, Outline, PixelCompare)")
struct TextCloseoutParityTests {
    // MARK: - text/measure/ink_tests.rs (4 tests)

    @Test
    func inkSitsInsideTheBoxAndSpacesHaveNone() {
        let style = TextStyle(size: 12.0, weight: 400.0).lh(16.0)
        let box = TextSystem().measure("H", style: style, maxWidth: nil, pixelScale: 1.0)
        let hInk = ink("H", style: style)
        #expect(hInk != nil)
        if let hInk {
            let x = hInk.bounds[0]
            let y = hInk.bounds[1]
            let iw = hInk.bounds[2]
            let ih = hInk.bounds[3]
            #expect(x >= 0.0 && y >= 0.0 && x + iw <= box.x && y + ih <= box.y)
            #expect(ih > 7.0 && ih < 10.0)
            let centre = hInk.centre()
            #expect(abs(hInk.mass[0] - centre[0]) < 0.2)
            let opt = hInk.optical(pull: 0.3)
            #expect(abs(opt[0] - (centre[0] + (hInk.mass[0] - centre[0]) * 0.3)) < 0.001)
        }
        #expect(ink(" ", style: style) == nil)
        #expect(ink("", style: style) == nil)
    }

    @Test
    func aWiderWordHasWiderInk() {
        let style = TextStyle(size: 12.0, weight: 400.0)
        let one = ink("H", style: style)
        let two = ink("HH", style: style)
        #expect(one != nil && two != nil)
        if let one, let two {
            #expect(two.bounds[2] > one.bounds[2] * 1.8)
        }
    }

    @Test
    func textInkCacheStaysBoundedInEntriesAndBytes() {
        let style = TextStyle(size: 12.0, weight: 400.0)
        var cache = TextInkCache()
        for i in 0..<(TextInkCache.maxEntries + 50) {
            let text = "t\(i)"
            cache.insert(key: TextInkCache.key(text: text, style: style), text: text, style: style, ink: nil)
        }
        #expect(cache.entries.count == TextInkCache.maxEntries)
        #expect(cache.order.count == TextInkCache.maxEntries)
        #expect(cache.get(key: TextInkCache.key(text: "t0", style: style), text: "t0", style: style) == nil)
        let last = "t\(TextInkCache.maxEntries + 49)"
        let lastHit = cache.get(key: TextInkCache.key(text: last, style: style), text: last, style: style)
        #expect(lastHit == .some(nil))

        let long = String(repeating: "x", count: TextInkCache.maxBytes / 8)
        for i in 0..<16 {
            let text = "\(long)\(i)"
            cache.insert(key: TextInkCache.key(text: text, style: style), text: text, style: style, ink: nil)
        }
        #expect(cache.bytes <= TextInkCache.maxBytes)
        let actualSum = cache.entries.values.reduce(0) { $0 + $1.bytes }
        #expect(cache.bytes == actualSum)

        let huge = String(repeating: "x", count: TextInkCache.maxBytes)
        cache.insert(key: TextInkCache.key(text: huge, style: style), text: huge, style: style, ink: nil)
        #expect(cache.get(key: TextInkCache.key(text: huge, style: style), text: huge, style: style) == nil)
    }

    @Test
    func textInkCacheChecksTextAndStyleNotOnlyHash() {
        let style = TextStyle(size: 12.0, weight: 400.0)
        var cache = TextInkCache()
        let sampleInk = TextInk(bounds: [1.0, 2.0, 3.0, 4.0], mass: [2.0, 3.0])
        cache.insert(key: 7, text: "H", style: style, ink: sampleInk)
        #expect(cache.get(key: 7, text: "H", style: style) == .some(sampleInk))
        #expect(cache.get(key: 7, text: "I", style: style) == nil)
        #expect(cache.get(key: 7, text: "H", style: TextStyle(size: 13.0, weight: 400.0)) == nil)
        cache.insert(key: 7, text: "I", style: style, ink: nil)
        #expect(cache.get(key: 7, text: "I", style: style) == .some(nil))
        #expect(cache.entries.count == 1)
        #expect(cache.order.count == 1)
    }

    // MARK: - text/mask_cache.rs

    @Test
    func maskCacheEncodeDecodeRoundTripAndValidation() {
        let stamp: UInt64 = 0x1234_5678_9ABC_DEF0
        let k1 = MaskCache.StableKey(font: 0xAA, index: 1, glyph: 42, size: 160, subpx: 2, apple: 1, bold: false, color: false)
        let k2 = MaskCache.StableKey(font: 0xBB, index: 0, glyph: 99, size: 200, subpx: 0, apple: 0, bold: true, color: true)
        let kBlank = MaskCache.StableKey(font: 0xAA, index: 0, glyph: 3, size: 160)

        let bytes = MaskCache.encode(
            stamp: stamp,
            items: [
                MaskCache.SnapshotEntry(key: k1, width: 2, height: 2, left: -1, top: 8, lcd: true, color: false, bytes: [10, 20, 30, 40]),
                MaskCache.SnapshotEntry(key: k2, width: 1, height: 1, left: 2, top: 10, lcd: false, color: true, bytes: [255, 128, 64, 255]),
                MaskCache.SnapshotEntry(key: kBlank, width: 0, height: 0, left: 0, top: 0, lcd: false, color: false, bytes: []),
            ]
        )

        let decoded = MaskCache.decode(bytes, stamp: stamp)
        #expect(decoded != nil)
        if let decoded {
            #expect(decoded.count == 3)
            #expect(!decoded.isEmpty)
            #expect(decoded.hasColor)
            #expect(decoded.entries[k1]?.lcd == true)
            #expect(decoded.entries[k1]?.left == -1)
            #expect(Array(decoded.bytes(for: k1) ?? []) == [10, 20, 30, 40])
            #expect(Array(decoded.bytes(for: k2) ?? []) == [255, 128, 64, 255])
            #expect(Array(decoded.bytes(for: kBlank) ?? []) == [])
        }

        // Wrong stamp, corrupt magic, or macOS nil buildStamp rejects cleanly
        #expect(MaskCache.decode(bytes, stamp: stamp ^ 1) == nil)
        #expect(MaskCache.decode(bytes, stamp: nil) == nil)
        var badMagic = bytes
        badMagic[0] = UInt8(ascii: "X")
        #expect(MaskCache.decode(badMagic, stamp: stamp) == nil)
        #expect(MaskCache.decode(bytes).isEmpty) // buildStamp() is nil on non-Windows
    }

    @Test
    func maskCacheRespectsBudgetAndEarlierOrder() {
        let stamp: UInt64 = 77
        let kOld1 = MaskCache.StableKey(font: 1, glyph: 1, size: 100)
        let kOld2 = MaskCache.StableKey(font: 1, glyph: 2, size: 100)
        let oldBytes = MaskCache.encode(
            stamp: stamp,
            items: [
                MaskCache.SnapshotEntry(key: kOld1, width: 4, height: 1, left: 0, top: 0, bytes: [1, 2, 3, 4]),
                MaskCache.SnapshotEntry(key: kOld2, width: 4, height: 1, left: 0, top: 0, bytes: [5, 6, 7, 8]),
            ]
        )
        let earlier = MaskCache.decode(oldBytes, stamp: stamp)
        let kNew = MaskCache.StableKey(font: 2, glyph: 9, size: 100)
        // Budget = 8 allows kNew (4) + kOld1 (4), drops kOld2 (4).
        let merged = MaskCache.encode(
            stamp: stamp,
            items: [
                MaskCache.SnapshotEntry(key: kNew, width: 4, height: 1, left: 0, top: 0, bytes: [9, 9, 9, 9]),
            ],
            earlier: earlier,
            budget: 8
        )
        let decoded = MaskCache.decode(merged, stamp: stamp)
        #expect(decoded?.count == 2)
        #expect(decoded?.bytes(for: kNew) != nil)
        #expect(decoded?.bytes(for: kOld1) != nil)
        #expect(decoded?.bytes(for: kOld2) == nil)
    }

    @Test
    func maskCacheSavingCadenceMachineAndFontIdentity() {
        var machine = MaskCacheSaving.unstarted
        // Poll before first frame does nothing
        #expect(machine.step(.poll(now: 1.0, placed: 5)).isEmpty)
        // First frame enters settling and requests wakeIn(3.0)
        #expect(machine.step(.frame(now: 1.0, placed: 5)) == [.wakeIn(MaskCache.settleInterval)])
        // Before 3.0s elapsed: no write
        #expect(machine.step(.poll(now: 3.5, placed: 5)).isEmpty)
        // At 4.0s (3.0s elapsed): write triggers
        #expect(machine.step(.poll(now: 4.0, placed: 5)) == [.write])

        let done = MaskCacheAtomicFlag(false)
        machine.markWriting(done: done, placed: 5)
        #expect(machine.step(.frame(now: 5.0, placed: 6)).isEmpty)
        done.store(true)
        #expect(machine.step(.poll(now: 6.0, placed: 6)).isEmpty) // transitions to .written(at: 6.0, placed: 5)
        // Within BETWEEN (30s): does not write even when placed changed
        #expect(machine.step(.frame(now: 20.0, placed: 6)).isEmpty)
        // After BETWEEN (30s) with placed != 5: writes
        #expect(machine.step(.poll(now: 36.0, placed: 6)) == [.write])

        // Stable fontIdentity across calls and sensitive to edits
        let bytesA = [UInt8](repeating: 0x41, count: 256)
        let bytesB = [UInt8](repeating: 0x42, count: 256)
        #expect(MaskCache.fontIdentity(bytesA) == MaskCache.fontIdentity(bytesA))
        #expect(MaskCache.fontIdentity(bytesA) != MaskCache.fontIdentity(bytesB))
    }

    // MARK: - text/outline.rs + outline/* + atlas_fill.rs + fill_bench.rs

    @Test
    func outlineBuilderCoverageAndFillParityBetweenLanes() {
        // Simple 100x100 square glyph in 1000 upem font space
        let square: [OutlinePathCommand] = [
            .moveTo(SIMD2<Double>(0, 0)),
            .lineTo(SIMD2<Double>(100, 0)),
            .lineTo(SIMD2<Double>(100, 100)),
            .lineTo(SIMD2<Double>(0, 100)),
            .close,
        ]
        let built = OutlineBuilder.build(commands: square, unit: 1.0, skew: 0.0, upem: 1000.0)
        #expect(built != nil)
        guard let built else { return }
        #expect(built.bbox == SIMD4<Float>(0, 0, 100, 100))

        let store = OutlineStore()
        let key = OutlineStore.Key(font: 1, glyph: 65, hinted: OutlineHinting.none.key())
        let found = store.glyph(key) { built }
        guard case .outline(let glyph) = found else {
            Issue.record("expected .outline")
            return
        }
        #expect(store.hasRecords)
        #expect(store.takeDirty() != nil)

        // Coverage inside square center is 1.0; well outside is 0.0
        let scale: Float = 0.2 // 100 units -> 20x20 px box
        let inside = OutlineCover.coverage(
            store: store,
            record: glyph.record,
            local: SIMD2<Float>(10.0, 10.0),
            scale: scale
        )
        let outside = OutlineCover.coverage(
            store: store,
            record: glyph.record,
            local: SIMD2<Float>(25.0, 10.0),
            scale: scale
        )
        #expect(inside > 0.99)
        #expect(outside == 0.0)

        // CPU fillMask vs 1-lane and 4-lane shareRows/fillShared produce identical bytes
        let fill = OutlineFillParams(record: glyph.record, scale: scale, radius: 0, pen: SIMD2<Float>(1.0, 21.0))
        let mask4 = OutlineMaskFiller.fillMask(store: store, fill: fill, atX: 4, atY: 4, width: 22, height: 22)
        #expect(mask4.count == 22 * 22)
        #expect(mask4.contains(255))
        #expect(mask4.contains(0))

        let queued = [QueuedOutlineFill(rect: SIMD4<UInt32>(4, 4, 22, 22), fill: fill)]
        let fillSet = OutlineFillSet(store: store, fills: queued)
        let bytesNative = fillSet.bytes(lanes: .native)
        let bytesScalar = fillSet.bytes(lanes: .one)
        #expect(bytesNative == bytesScalar)
        #expect(bytesNative == mask4)
        let census = fillSet.census()
        #expect(census.texels == 22 * 22)
        #expect(census.solid > 0)
        #expect(census.clear > 0)

        // Outline rect & RasterPath state machine + AtlasFillResidency machine
        let outline = GlyphOutline(pen: SIMD2<Float>(10, 50), scale: scale, zoom: 2.0, record: glyph.record, hint: 0, radius: 0.5)
        let rect = outline.rect(bbox: glyph.bbox)
        #expect(rect[2] > 40.0 && rect[3] > 40.0)

        var paths = OutlinePaths()
        let (p0, e0) = paths.step(node: 42, frame: .moving)
        #expect(p0 == .moving && e0.isEmpty && p0.emit == .outline)
        paths.beginFrame()
        let (p1, e1) = paths.step(node: 42, frame: .resting)
        #expect(p1 == .landing && e1 == [.placeMasks] && p1.emit == .outline)
        paths.beginFrame()
        let (p2, e2) = paths.step(node: 42, frame: .resting)
        #expect(p2 == .still && e2.isEmpty && p2.emit == .atlas)

        var res = AtlasFillResidency.pending(page: 0, x: 0, y: 0, w: 10, h: 10, fill: fill)
        #expect(res.step(.fillRan).isEmpty)
        #expect(res.step(.rowsUploaded(page: 0, y0: 0, y1: 12)) == [.queue])
        #expect(res.step(.filledOnCpu).isEmpty)
    }

    // MARK: - text/pixel_compare.rs + pixel_compare_tests.rs (2 tests + helpers)

    @Test
    func pixelCompareHelpersAndDiffStatsWork() {
        let imgA = PixelCompareImage(
            width: 4, height: 2,
            rgb: [
                250, 250, 250,  250, 250, 250,  20, 20, 20,  250, 250, 250,
                250, 250, 250,  250, 250, 250,  20, 20, 20,  250, 250, 250,
            ]
        )
        let imgB = PixelCompareImage(
            width: 4, height: 2,
            rgb: [
                250, 250, 250,  250, 250, 250,  100, 100, 100,  250, 250, 250,
                250, 250, 250,  250, 250, 250,  20, 20, 20,     250, 250, 250,
            ]
        )
        let stats = PixelCompare.statsIn(rune: imgA, reference: imgB, rect: [0, 0, 4, 2])
        #expect(stats.pixels == 8)
        #expect(stats.differing == 1)
        #expect(stats.over8 == 1)
        #expect(stats.max == 80)

        let heat = PixelCompare.heatmap(rune: imgA, reference: imgB)
        #expect(heat.width == 4 && heat.height == 2)
        // Pixel (2, 0) had more ink in imgA (20 on 250 paper) than imgB (100 on 250 paper) -> blue tint (B > R)
        let p = heat.pixel(x: 2, y: 0)
        #expect(p.2 > p.0)

        #expect(!PixelCompare.cases(for: .inter).isEmpty)
        #expect(PixelCompare.sheetHeight(for: .inter) > 100)
        #expect(!PixelCompare.layoutFile(for: .inter).isEmpty)
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
    @Test
    func macosSmoothingAndUnsmoothedStayNearCoreText() throws {
        // Run PixelCompare with live CoreText reference generation on macOS for representative cases
        let smoothOpts = PixelCompareOptions(set: .sf, smoothing: .on, srgbBlend: true)
        let smoothRows = try PixelCompare.run(options: smoothOpts, useLiveReferenceOnMacOS: true)
        #expect(!smoothRows.isEmpty)
        let smoothSample = PixelCompare.pooledStats(rows: smoothRows, pair: "light", scale: 2.0)
        #expect(smoothSample.pixels > 0)
        #expect(smoothSample.inkRatio >= 0.5 && smoothSample.inkRatio <= 1.6)

        let flatOpts = PixelCompareOptions(set: .sf, smoothing: .off, srgbBlend: true)
        let flatRows = try PixelCompare.run(options: flatOpts, useLiveReferenceOnMacOS: true)
        let flatSample = PixelCompare.pooledStats(rows: flatRows, pair: "light", scale: 2.0)
        #expect(flatSample.pixels > 0)
        #expect(flatSample.inkRatio >= 0.5 && flatSample.inkRatio <= 1.6, "flat inkRatio=\(flatSample.inkRatio) rune=\(flatSample.inkRune) ref=\(flatSample.inkRef)")
    }
    #endif
}
