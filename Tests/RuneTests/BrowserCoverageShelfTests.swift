import Testing
@testable import Rune

@Suite struct BrowserCoverageShelfTests {
    @Test func exactPixelsShareAnOccupiedRectangleUntilTheShelfResets() {
        let size = SIMD2(2, 2), origin = SIMD2(1, 1), stride = 4
        let page: [UInt8] = [9, 9, 9, 9, 9, 1, 2, 9, 9, 3, 4, 9]
        let pixels: [UInt8] = [1, 2, 3, 4]
        let hash = BrowserCoverageShelf.fingerprint(pixels, size: size)
        var shelf = BrowserCoverageShelf()
        shelf.remember(hash, origin: origin, size: size)
        #expect(shelf.origin(hash, pixels: pixels, size: size, page: page, stride: stride) == origin)
        // A real collision can land on the same rectangle at the same dimensions.
        #expect(shelf.origin(hash, pixels: [1, 2, 3, 5], size: size, page: page, stride: stride) == nil)
        #expect(shelf.origin(hash, pixels: pixels, size: SIMD2(1, 4), page: page, stride: stride) == nil)
        shelf.reset()
        #expect(shelf.origin(hash, pixels: pixels, size: size, page: page, stride: stride) == nil)
    }

    @Test func invalidBufferGeometryNeverReadsOutsideEitherBuffer() {
        let size = SIMD2(2, 2), pixels: [UInt8] = [1, 2, 3, 4]
        var shelf = BrowserCoverageShelf()
        shelf.remember(1, origin: .zero, size: size)
        #expect(shelf.origin(1, pixels: [1, 2, 3], size: size, page: pixels, stride: 2) == nil)
        #expect(shelf.origin(1, pixels: pixels, size: size, page: [1, 2, 3], stride: 2) == nil)
        #expect(shelf.origin(1, pixels: pixels, size: size, page: pixels, stride: 0) == nil)
        shelf.remember(1, origin: SIMD2(1, Int.max), size: size)
        #expect(shelf.origin(1, pixels: pixels, size: size, page: pixels, stride: 3) == nil)
        let impossible = SIMD2(Int.max, 2)
        shelf.remember(1, origin: .zero, size: impossible)
        #expect(shelf.origin(1, pixels: pixels, size: impossible, page: pixels, stride: Int.max) == nil)
    }
}
