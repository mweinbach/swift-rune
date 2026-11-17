import Testing
@testable import Rune

@Suite struct WebAtlasUpdateTests {
    @Test func fullUploadInitializesAndResizesTheResidentAtlas() {
        let pixels = [UInt8](repeating: 7, count: 100)
        #expect(WebAtlasUpdate.update(width: 10, height: 10, channels: 1,
            texels: pixels, previous: nil, changed: false) == .full)
        #expect(WebAtlasUpdate.update(width: 10, height: 10, channels: 1,
            texels: pixels, previous: [0], changed: false) == .full)
        #expect(WebAtlasUpdate.update(width: Int.max, height: 10, channels: 4,
            texels: pixels, previous: pixels, changed: true) == .full)
    }

    @Test func unchangedGenerationAndContentSkipUploads() {
        let pixels = [UInt8](repeating: 3, count: 256)
        let duplicate = pixels.map { $0 }
        #expect(WebAtlasUpdate.update(width: 16, height: 16, channels: 1,
            texels: pixels, previous: pixels, changed: true) == .none)
        #expect(WebAtlasUpdate.update(width: 16, height: 16, channels: 1,
            texels: duplicate, previous: pixels, changed: true) == .none)
        #expect(WebAtlasUpdate.update(width: 16, height: 16, channels: 1,
            texels: duplicate, previous: pixels, changed: false) == .none)
    }

    @Test func glyphAndImageDiffsRoundByteChangesOutwardToTexels() {
        for channels in [1, 4] {
            let before = [UInt8](repeating: 0, count: 10 * 20 * channels)
            var after = before
            after[(3 * 10 + 9) * channels + channels - 1] = 7
            after[(8 * 10 + 8) * channels] = 9
            #expect(WebAtlasUpdate.update(width: 10, height: 20, channels: channels,
                texels: after, previous: before, changed: true) == .patch(SIMD4(8, 3, 10, 9)))
        }
    }

    @Test func trustedBoundsSkipTheScanAndInvalidBoundsFallBackToComparison() {
        let before = [UInt8](repeating: 0, count: 32 * 8 * 4)
        var after = before
        after[(3 * 32 + 6) * 4 + 1] = 1
        let writes = SIMD4(4, 2, 10, 5)
        #expect(WebAtlasUpdate.update(width: 32, height: 8, channels: 4,
            texels: after, previous: before, changed: true, knownEdges: writes) == .patch(writes))
        for invalid in [SIMD4(0, 0, 40, 8), SIMD4(-1, 0, 6, 7), SIMD4(4, 2, 3, 1)] {
            #expect(WebAtlasUpdate.update(width: 32, height: 8, channels: 4,
                texels: after, previous: before, changed: true, knownEdges: invalid) == .patch(SIMD4(6, 3, 7, 4)))
        }
    }

    @Test func fullUploadWinsWhenRectangleHeaderWouldConsumeTheSavings() {
        let before = [UInt8](repeating: 0, count: 32)
        var after = before
        after[0] = 1
        after[15] = 2
        #expect(WebAtlasUpdate.update(width: 32, height: 1, channels: 1,
            texels: after, previous: before, changed: true) == .full)
        after[15] = 0
        after[14] = 2
        #expect(WebAtlasUpdate.update(width: 32, height: 1, channels: 1,
            texels: after, previous: before, changed: true) == .patch(SIMD4(0, 0, 15, 1)))
    }
}
