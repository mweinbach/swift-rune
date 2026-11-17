#if canImport(CRuneDesktopText) && !canImport(CoreText) && (os(Linux) || os(Windows))
import Testing
@testable import Rune

@Suite("Retained native glyph atlas pages")
struct RetainedNativeGlyphPageTests {
    @Test func finishingAnOlderBuildCannotCacheGlyphsFromARecycledPage() {
        let replay = GlyphReplayCache()
        let shape = TextShapeKey(authText: "Hi", spans: nil, pills: [], style: TextStyle(size: 16),
                                 pixelScale: 1, fontEpoch: 0, languageTag: nil, maxWidth: nil)
        let first = GlyphReplayKey(shapeKey: shape, maxWidth: 80, glidePx: .zero)
        let second = GlyphReplayKey(shapeKey: shape, maxWidth: 40, glidePx: .zero)
        let old = PositionedGlyph(rect: SIMD4(0, 0, 1, 1), uv: SIMD4(0, 0, 0.25, 0.25))
        let new = PositionedGlyph(rect: old.rect, uv: SIMD4(0, 0.5, 0.25, 0.75))

        // Complete a draw from the recycled atlas while the older flatten is in flight.
        _ = replay.glyphsInBandCached(key: first, keep: .cached, bandTopPt: 0, bandBottomPt: 1, sinceAtlasResets: 0) {
            _ = replay.glyphsInBandCached(key: second, keep: .cached, bandTopPt: 0, bandBottomPt: 1, sinceAtlasResets: 1) {
                ([new], [0..<1], 1)
            }
            return ([old], [0..<1], 1)
        }
        let current = replay.glyphsInBandCached(key: first, keep: .cached, bandTopPt: 0, bandBottomPt: 1, sinceAtlasResets: 1) {
            ([new], [0..<1], 1)
        }
        #expect(current.first?.uv == new.uv)
    }

    @Test func returningToAnIntegralOriginAfterPageReuseRecoversTheOriginalInk() throws {
        let atlas = GlyphAtlas(width: 64, height: 64)
        let runtime = Runtime(state: (), viewport: Vec2(120, 44), pixelScale: 1,
                              textSystem: TextSystem(glyphAtlas: atlas)) { _, _ in
            col().sizeFull().center().bg(.black).child(
                text("Hi").key("label").w(80).font(TextStyle(size: 16, family: .custom("Inter"))).color(.white)
            )
        }
        runtime.fontSmoothing = .windfoil
        runtime.srgbBlend = true
        let original = try RuneRef.render(runtime.frame(at: 0))
        try #require(stride(from: 0, to: original.rgba.count, by: 4).contains { original.rgba[$0] > 0 })

        runtime.setViewport(Vec2(120.5, 44))
        _ = runtime.frame(at: 1)
        let bounds = try #require(runtime.lastElements.first { $0.key == "label" }?.target)
        try #require(bounds[0] == 20.25)
        try #require(atlas.pageCount == 1)

        // The label's old UVs now point to an empty mask owned by another draw.
        atlas.evictPage(0)
        let replacement = try #require(atlas.placeMask(width: 62, height: 32, bitmap: Array(repeating: 0, count: 62 * 32)))
        try #require(replacement.page == 0)

        runtime.setViewport(Vec2(120, 44))
        let recovered = try RuneRef.render(runtime.frame(at: 2))
        #expect(recovered.width == original.width && recovered.height == original.height)
        let changedBytes = zip(original.rgba, recovered.rgba).count { $0 != $1 }
        #expect(changedBytes == 0)
    }
}
#endif
