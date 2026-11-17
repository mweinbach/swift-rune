import Foundation
import Rune
import RuneRef
import Testing

@Suite("Gzip-compressed SVG images")
struct ImageCacheSVGZTests {
    private static let svg = Data(
        ##"<svg xmlns="http://www.w3.org/2000/svg" width="6" height="2"><rect width="3" height="2" fill="#00ff00"/></svg>"##.utf8
    )
    // This gzip member includes an extra field, original filename, comment, and header CRC.
    private static let svgz = Data(base64Encoded:
        "H4sIHgAAAAAA/wQAUlUAAGV4YW1wbGUuc3ZnAFJ1bmUAsYxNzEkKgDAMQNGrlLg3oQUX0vYyageoA20wHl9dCK7f59t2RnWtZWsOEvMxIopIL6bfa0RNRPgUoCTPnBwMoNKSY2IHGryty8QfmT+pkEtx0BGFQATo7bvxN2fyGONuAAAA"
    )!

    private func checkRaster(_ image: CachedImage, width: Int, height: Int) async throws {
        let (w, h) = try await image.decodedSizeForTest()
        try #require(Int(w) == width && Int(h) == height)
        let rgba = image.pixels.rgbaBytes()
        try #require(rgba.count == width * height * 4)
        let inside = 4 * ((height / 2) * width + width / 4)
        let outside = 4 * ((height / 2) * width + 3 * width / 4)
        #expect(Array(rgba[inside..<(inside + 4)]) == [0, 255, 0, 255])
        #expect(Array(rgba[outside..<(outside + 4)]) == [0, 0, 0, 0])
    }

    @Test func compressedBytesPaintAtDoubleIntrinsicSize() async throws {
        let cache = ImageCache()
        let compressed = cache.load(Self.svgz)
        try await checkRaster(compressed, width: 12, height: 4)
        let plain = cache.load(Self.svg)
        try await plain.decodedSizeForTest()
        #expect(compressed.pixels.rgbaBytes() == plain.pixels.rgbaBytes())
    }

    #if !os(WASI)
    @Test func localFileURLsUseTheRequestedSizeWithAndWithoutTheSVGZExtension() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageCache()
        for name in ["asset.svgz", "asset"] {
            let file = directory.appendingPathComponent(name)
            try Self.svgz.write(to: file)
            let image = cache.url(file.absoluteString, sizePt: 9, scale: 2)
            try await checkRaster(image, width: 18, height: 6)
        }
    }
    #endif

    @Test func gzipVerifiesEachMemberAndEnforcesTheCombinedOutputLimit() throws {
        let input = Self.svgz + Self.svgz
        let expected = Self.svg + Self.svg
        #expect(try PortablePNG.gunzip(input, maximumSize: expected.count) == expected)
        #expect(throws: (any Error).self) {
            try PortablePNG.gunzip(input, maximumSize: expected.count - 1)
        }
        #expect(throws: (any Error).self) {
            try PortablePNG.gunzip(Self.svgz, maximumSize: Self.svg.count - 1)
        }
    }

    @Test func corruptedSVGZAndCompressedNonSVGFailToLoad() throws {
        // The timestamp participates in the header CRC. The last eight bytes hold CRC32 and ISIZE.
        let bytes = Self.svgz
        for index in [4, bytes.count - 8, bytes.count - 4] {
            var corrupt = bytes
            corrupt[index] ^= 1
            #expect(throws: (any Error).self) {
                try PortablePNG.gunzip(corrupt, maximumSize: Self.svg.count)
            }
        }
        #expect(throws: (any Error).self) {
            try PortablePNG.gunzip(bytes.dropLast(1), maximumSize: Self.svg.count)
        }
        let text = try #require(Data(base64Encoded: "H4sIAAAAAAAC/8vLL1EoLksHAPpAI+8HAAAA"))
        #expect(throws: ImageLoadError.self) {
            try ImageCache().load(text).wait().get()
        }
    }
}
