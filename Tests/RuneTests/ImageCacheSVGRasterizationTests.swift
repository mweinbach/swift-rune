import Foundation
import Rune
import Testing

@Suite("SVG image cache pixels")
struct ImageCacheSVGRasterizationTests {
    private func pixel(_ rgba: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        let start = 4 * (y * width + x)
        return Array(rgba[start..<(start + 4)])
    }

    @Test func encodedSVGPaintsEachShapeInTheOffsetViewBox() throws {
        let svg = ##"""
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="8" viewBox="10 20 16 8">
          <rect x="11" y="21" width="4" height="4" fill="#00ff00"/>
          <path d="M16 21h4v3h-4z" fill="#0000ff"/>
          <g transform="translate(20 23)">
            <circle cx="2" cy="2" r="1.6" fill="#ff0000" fill-opacity="0.5"/>
          </g>
        </svg>
        """##
        let handle = ImageCache().load(Data(svg.utf8))
        let (width, height) = try handle.wait().get()
        try #require(width == 32 && height == 16)
        let rgba = handle.pixels.rgbaBytes()
        try #require(rgba.count == 32 * 16 * 4)
        #expect(pixel(rgba, width: 32, x: 5, y: 5) == [0, 255, 0, 255])
        #expect(pixel(rgba, width: 32, x: 15, y: 4) == [0, 0, 255, 255])
        // Mip zero stores red premultiplied by 0.5 in linear light, then encoded as sRGB.
        #expect(pixel(rgba, width: 32, x: 24, y: 10) == [188, 0, 0, 128])
        #expect(pixel(rgba, width: 32, x: 0, y: 0) == [0, 0, 0, 0])
    }

    @Test func fetchedSVGCentersViewBoxAndPreservesDocumentPaintDefaults() throws {
        let svg = ##"""
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="12" viewBox="0 0 6 6" color="#0080ff">
          <rect width="3" height="6"/>
          <path d="M3 0h3v6H3z" fill="currentColor"/>
        </svg>
        """##
        let image = ImageCache().load(url: "asset.svg", sizePt: 12, scale: 2, fetched: .svg(Data(svg.utf8)))
        let (width, height) = try image.wait().get()
        try #require(width == 24 && height == 12)
        let rgba = image.pixels.rgbaBytes()
        try #require(rgba.count == 24 * 12 * 4)
        #expect(pixel(rgba, width: 24, x: 3, y: 6) == [0, 0, 0, 0])
        #expect(pixel(rgba, width: 24, x: 7, y: 6) == [0, 0, 0, 255])
        #expect(pixel(rgba, width: 24, x: 16, y: 6) == [0, 128, 255, 255])
        #expect(pixel(rgba, width: 24, x: 20, y: 6) == [0, 0, 0, 0])
    }
}
