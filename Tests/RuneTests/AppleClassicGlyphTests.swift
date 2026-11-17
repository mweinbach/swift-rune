#if canImport(CoreText) && canImport(CoreGraphics)
import CoreText
import Foundation
import Testing
@testable import Rune

@Suite("CoreGraphics classic glyph coverage")
struct AppleClassicGlyphTests {
    @Test("The eight RuneHello glyphs reproduce their recorded Rust A8 masks")
    func helloMasksMatchRustRecording() throws {
        let face = try fontDescriptor()
        let font = CTFontCreateWithFontDescriptor(face, 13, nil)
        let raster = AppleClassicGlyph()
        // RuneHello --scene on --size 320x200 --scale 1 from upstream 842c28c2.
        // Its bright label takes luminance bucket 3 and three different pen phases.
        let phases: [Float] = [0, 1 / 3, 2 / 3, 0, 0, 1 / 3, 2 / 3, 2 / 3]
        let hashes: [UInt64] = [
            0x6568c1ae5ba1ae96, 0xdc27a77f817c4b05, 0x8760f936f7357811, 0x48139020d4b73afb,
            0x07e8ac0364872eb0, 0xb0bb2db99fdaee44, 0x9cac18b1f2847305, 0x8589c79db40ae18d
        ]
        for (i, character) in "Lightson".utf16.enumerated() {
            let glyph = try glyphID(character, font: font)
            let result = try #require(raster.mask(font: font, glyph: glyph, ppem: 13, phase: phases[i], shiftY: 0,
                                                  pipeline: .smoothed, bucket: 3, maximumSide: 2048))
            #expect(checksum(result.bytes) == hashes[i])
        }
    }

    @Test("Classic masks retain their bearings and coverage during fractional glides")
    func phasesMatchRust() throws {
        let face = try fontDescriptor()
        let raster = AppleClassicGlyph()
        let cases: [(UInt16, Float, Float, Float, ApplePipeline, UInt8, SIMD4<Int>, UInt64)] = [
            (66, 8, 0, 0.25, .unsmoothed, 0, SIMD4(0, -6, 5, 7), 0x72a732ac1ad33908),
            (81, 11.5, 0.5, 0.75, .smoothed, 0, SIMD4(1, -8, 8, 10), 0x4f6a446961962002),
            (106, 26, 2 / 3, 0, .unsmoothed, 3, SIMD4(0, -20, 6, 26), 0x2b1752e6b99269e0)
        ]
        for (character, ppem, phase, glide, pipeline, bucket, box, hash) in cases {
            let font = CTFontCreateWithFontDescriptor(face, CGFloat(ppem), nil)
            let glyph = try glyphID(character, font: font)
            let result = try #require(raster.mask(font: font, glyph: glyph, ppem: ppem, phase: phase, shiftY: glide,
                                                  pipeline: pipeline, bucket: bucket, maximumSide: 2048))
            #expect(SIMD4(Int(result.bearing.x), Int(result.bearing.y), result.width, result.height) == box)
            #expect(checksum(result.bytes) == hash)
        }
    }

    @Test("An explicit light ink allocates one small mask on the first frame")
    @MainActor
    func requestedInkIsUsedAtShapeTime() {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(100, 40), pixelScale: 1) { _, _ in
            el().size(100, 40).child(
                text("A").absolute(x: 0, y: 0).font(TextStyle(size: 13, weight: 600, fontSmoothing: .on)).color(.white)
            )
        }
        let frame = runtime.renderFrame(at: 0)
        #expect(frame.instances.filter { $0.params.y == KIND_GLYPH }.count == 1)
        #expect(runtime.textSystem.glyphAtlas.rasterized == 1)
    }

    private func fontDescriptor() throws -> CTFontDescriptor {
        let url = try #require(DefaultFonts.fontURL(named: "Inter-SemiBold"))
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        return try #require(descriptors?.first)
    }

    private func glyphID(_ character: UInt16, font: CTFont) throws -> CGGlyph {
        var utf16 = character, glyph: CGGlyph = 0
        try #require(CTFontGetGlyphsForCharacters(font, &utf16, &glyph, 1))
        return glyph
    }

    private func checksum(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
#endif
