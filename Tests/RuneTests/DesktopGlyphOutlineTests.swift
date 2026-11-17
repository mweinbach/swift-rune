#if os(Linux) || os(Windows)
import CRuneDesktopText
import Foundation
import Testing
@testable import Rune

@Suite("Native desktop glyph outlines")
struct DesktopGlyphOutlineTests {
    #if os(Linux)
    private let family = "DejaVu Sans"
    #else
    private let family = "Segoe UI"
    #endif

    @Test func windfoilInkUsesTheSameCurvesWithForegroundSpecificAtRestAndMovingCoverage() throws {
        let system = TextSystem()
        let style = TextStyle(size: 20, family: .custom(family), fontSmoothing: .windfoil)
        let shaped = system.shape(text: "R", style: style, maxWidth: nil, pixelScale: 1)
        let original = try #require(shaped.glyphs.first)
        let desktop = try #require(shaped.desktopRestingText)
        let dark = try #require(desktop.outlineGroup(for: original, line: 0, shaped: shaped, atlas: system.glyphAtlas))
        let (lighter, _) = system.glyphAtlas.outlineInk(original, rect: original.rect, bucket: 4)
        let light = try #require(lighter.outlineGroup)
        let a = try #require(dark.glyphs.first?.outline), b = try #require(light.glyphs.first?.outline)
        #expect(a.record == b.record)
        #expect(a.radius == Float(GlyphOutline.dilation(ppem: 20, inkBucket: 0)))
        #expect(b.radius == Float(GlyphOutline.dilation(ppem: 20, inkBucket: 4)))
        let cached = system.glyphAtlas.outlineInk(original, rect: original.rect, bucket: 4).0
        #expect(cached.uv == lighter.uv && cached.atlasPage == lighter.atlasPage)
        func totalCoverage(_ glyph: PositionedGlyph) throws -> Int {
            let page = try #require(system.glyphAtlas.pageData(Int(glyph.atlasPage)))
            let atlas = system.glyphAtlas.pagePixelSize
            let uv = glyph.uv * SIMD4(Float(atlas.x), Float(atlas.y), Float(atlas.x), Float(atlas.y))
            var sum = 0
            for y in Int(uv.y.rounded())..<Int(uv.w.rounded()) {
                for x in Int(uv.x.rounded())..<Int(uv.z.rounded()) { sum += Int(page[y * atlas.x + x]) }
            }
            return sum
        }
        #expect(try totalCoverage(lighter) > totalCoverage(original))

        let zoom = Live<Float>(1)
        let runtime = Runtime<Live<Float>>(state: zoom, viewport: Vec2(160, 64), pixelScale: 1) { zoom, _ in
            row().liveScale(zoom.binding)
                .child(text("R").font(style).color(.black))
                .child(text("R").font(style).color(.white))
        }
        runtime.textSystem.outlineRendererSupport = { _ in (true, false) }
        _ = runtime.renderFrame(at: 0)
        zoom.set(1.15)
        let moving = runtime.renderFrame(at: 0.016).instances.filter { $0.params.y == KIND_GLYPH && $0.radii.w > 0 }
        let darkDraw = try #require(moving.first { $0.fill.x == 0 })
        let lightDraw = try #require(moving.first { $0.fill.x > 0.99 })
        #expect(lightDraw.border.z > darkDraw.border.z)
    }

    @Test func detachedRTLClusterKeepsItsInkAndContinuationHasNoContours() throws {
        let text = "zلاz"
        let raw = rune_desktop_line_create(text, Int32(text.utf8.count), family, 32, 400, 0, 0, 0)
        let line = try #require(raw)
        let owner = rune_desktop_line_extract_ink(line, 1, 3)
        let tail = rune_desktop_line_extract_ink(line, 3, 5)
        rune_desktop_line_destroy(line)
        defer { rune_desktop_line_destroy(owner); rune_desktop_line_destroy(tail) }

        func geometry(_ view: OpaquePointer?) throws -> Int {
            let view = try #require(view)
            var edges = 0
            let result = rune_desktop_line_outline(view, { state, command, _, _, _, _, _, _ in
                if command == 1 || command == 2 || command == 3 {
                    state!.assumingMemoryBound(to: Int.self).pointee += 1
                }
            }, &edges)
            try #require(result != 0)
            return edges
        }
        #expect(try geometry(owner) > 0)
        #expect(try geometry(tail) == 0)
    }

    @Test func repeatedLabelsShareTheShapedFaceAndGlyphIdentityAcrossLayouts() throws {
        let first = rune_desktop_line_create("home", 4, family, 24, 400, 0, 0, 0)
        let second = rune_desktop_line_create("help", 4, family, 24, 400, 0, 0, 0)
        let a = try #require(first)
        let b = try #require(second)
        defer { rune_desktop_line_destroy(a); rune_desktop_line_destroy(b) }
        func single(_ line: OpaquePointer, _ byte: Int32) throws -> (UInt64, UInt32) {
            var font: UInt64 = 0, glyph: UInt32 = 0
            var x: Float = 0, y: Float = 0
            try #require(rune_desktop_line_outline_single(line, byte, &font, &glyph, &x, &y) != 0)
            #expect(x.isFinite && y.isFinite)
            return (font, glyph)
        }
        let h = try single(a, 0), otherH = try single(b, 0), e = try single(b, 1)
        #expect(h.0 == otherH.0 && h.1 == otherH.1)
        #expect(otherH.0 == e.0 && otherH.1 != e.1)
    }

    @Test func intrinsicOutlineUsesTheOriginalFractionalShapedPen() throws {
        let text = "office zلاz"
        let raw = rune_desktop_line_create(text, Int32(text.utf8.count), family, 24.43, 400, 1, 0, 0)
        let line = try #require(raw)
        defer { rune_desktop_line_destroy(line) }
        let emit: RuneOutlineEmit = { state, command, x1, y1, x2, y2, x3, y3 in
            guard let state, command >= 1, command <= 3 else { return }
            let bounds = state.assumingMemoryBound(to: SIMD4<Float>.self)
            func include(_ x: Float, _ y: Float) {
                bounds.pointee = SIMD4(min(bounds.pointee.x, x), min(bounds.pointee.y, y),
                                       max(bounds.pointee.z, x), max(bounds.pointee.w, y))
            }
            include(x1, y1)
            if command >= 2 { include(x2, y2) }
            if command == 3 { include(x3, y3) }
        }
        for bytes: Range<Int32> in [1..<2, 8..<10] {
            let ink = try #require(rune_desktop_line_extract_ink(line, bytes.lowerBound, bytes.upperBound))
            defer { rune_desktop_line_destroy(ink) }
            var font: UInt64 = 0, glyph: UInt32 = 0, x: Float = 0, y: Float = 0
            try #require(rune_desktop_line_outline_single(line, bytes.lowerBound, &font, &glyph, &x, &y) != 0)
            var placed = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)
            var intrinsic = placed
            try #require(rune_desktop_line_outline(ink, emit, &placed) != 0)
            try #require(rune_desktop_line_outline_unplaced(line, bytes.lowerBound, emit, &intrinsic) != 0)
            let expected = intrinsic + SIMD4(x, y, x, y)
            for i in 0..<4 { #expect(placed[i].isFinite && abs(placed[i] - expected[i]) < 0.025) }
        }
    }

    #if os(Linux)
    @Test func pangoUsesLightAndTrueTypeHintedCurvesAtSmallSizes() throws {
        let size: Float = 15
        let raw = rune_desktop_line_create("H", 1, family, size, 400, 0, 0, 0)
        let line = try #require(raw)
        defer { rune_desktop_line_destroy(line) }
        func top(_ look: Int32) throws -> Float {
            var top = Float.infinity
            let ok = rune_linux_line_outline_fitted(line, 0, size, look, { state, cmd, _, y1, _, y2, _, y3 in
                guard let state, cmd < 4 else { return }
                let result = state.assumingMemoryBound(to: Float.self)
                result.pointee = min(result.pointee, y1)
                if cmd >= 2 { result.pointee = min(result.pointee, y2) }
                if cmd == 3 { result.pointee = min(result.pointee, y3) }
            }, &top)
            try #require(ok != 0)
            return top
        }
        let design = try top(Int32(RUNE_LINUX_HINT_DESIGN))
        let auto = try top(Int32(RUNE_LINUX_HINT_AUTO))
        let chromium = try top(Int32(RUNE_LINUX_HINT_CHROMIUM))
        #expect(auto.rounded() == auto && chromium.rounded() == chromium)
        #expect(design != auto && design != chromium && auto != chromium)

        var values = [Double](repeating: 0, count: 5)
        let loaded = values.withUnsafeMutableBufferPointer { rune_desktop_line_apple_hint_metrics(line, 0, $0.baseAddress) }
        #expect(loaded != 0)
        // True glyph control-point tops from named ‘o’ and ‘X’, in design units.
        #expect(values == [2048, 1147, 1493, 2524, 0])
    }
    #endif

    @Test func vectorTilesCoverNativeLigaturesOverhangsAndRTLInk() throws {
        let system = TextSystem()
        let style = TextStyle(size: 32, italic: true, family: .custom(family), fontSmoothing: .windfoilChromium)
        for text in ["office", "a\u{301}j", "zلاz"] {
            let shaped = system.shape(text: text, style: style, maxWidth: nil, pixelScale: 1)
            let desktop = try #require(shaped.desktopRestingText)
            var sharedPixels = 0, unionPixels = 0
            var filled = Set<SIMD2<Int>>()
            for glyph in shaped.glyphs {
                let group = try #require(desktop.outlineGroup(for: glyph, line: 0, shaped: shaped, atlas: system.glyphAtlas))
                let page = try #require(system.glyphAtlas.pageData(Int(glyph.atlasPage)))
                let width = system.glyphAtlas.atlas.width, height = system.glyphAtlas.atlas.height
                let px = Int((glyph.uv.x * Float(width)).rounded()), py = Int((glyph.uv.y * Float(height)).rounded())
                system.glyphAtlas.withOutlineStore { store in
                    for y in 0..<Int(group.size.y.rounded()) {
                        for x in 0..<Int(group.size.x.rounded()) {
                            let at = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                            let native = page[(py + y) * width + px + x] > 72
                            let vector = group.glyphs.contains { part in
                                let b = part.rect
                                guard at.x >= b.x && at.y >= b.y && at.x < b.x + b.z && at.y < b.y + b.w else { return false }
                                let offset = at - part.outline.pen
                                return OutlineCover.coverage(store: store, record: part.outline.record,
                                    local: SIMD2(offset.x, -offset.y), scale: part.outline.scale) > 0.28
                            }
                            if native { filled.insert(SIMD2(Int(glyph.rect.x.rounded()) + x, Int(glyph.rect.y.rounded()) + y)) }
                            if native && vector { sharedPixels += 1 }
                            if native || vector { unionPixels += 1 }
                        }
                    }
                }
            }
            var classicStyle = style
            classicStyle.fontSmoothing = .off
            let classic = system.shape(text: text, style: classicStyle, maxWidth: nil, pixelScale: 1)
            var nativeInk = Set<SIMD2<Int>>()
            for glyph in classic.glyphs {
                let page = try #require(system.glyphAtlas.pageData(Int(glyph.atlasPage)))
                let atlas = system.glyphAtlas.atlas
                let px = Int((glyph.uv.x * Float(atlas.width)).rounded())
                let py = Int((glyph.uv.y * Float(atlas.height)).rounded())
                for y in 0..<Int(glyph.rect.w.rounded()) {
                    for x in 0..<Int(glyph.rect.z.rounded()) where page[(py + y) * atlas.width + px + x] > 72 {
                        nativeInk.insert(SIMD2(Int(glyph.rect.x.rounded()) + x, Int(glyph.rect.y.rounded()) + y))
                    }
                }
            }
            let covered = nativeInk.union(filled)
            #expect(!covered.isEmpty)
            #expect(Double(nativeInk.intersection(filled).count) / Double(max(covered.count, 1)) > 0.72)
            #expect(unionPixels > 0)
            #expect(Double(sharedPixels) / Double(max(1, unionPixels)) > 0.72, "Shaped native/vector ink for \(text)")
        }
    }
}
#endif
