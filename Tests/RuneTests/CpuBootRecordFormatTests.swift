import Testing
@testable import Rune

@Suite("CPU boot draw.bin format")
struct CpuBootRecordFormatTests {
    // These are the little-endian fields of Rust's RCB1, through the glyph page count.
    private func header(pages: UInt32) -> [UInt8] {
        var bytes = Array("RCB1".utf8)
        for value: UInt32 in [4, 2, 0, 0, 0, Float(1).bitPattern, 0, 0, pages] {
            bytes += littleEndian(value)
        }
        return bytes
    }

    private func littleEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    @Test("Canonical image bytes start directly after the fixed-size glyph pages")
    func canonicalEncoding() throws {
        let texels: [UInt8] = [255, 0, 2, 255]
        let bytes = header(pages: 0) + littleEndian(1) + littleEndian(1) + littleEndian(1) + texels
        let record = try #require(CpuBootRecord.decode(bytes))
        #expect(record.images.count == 1)
        #expect(record.images.first?.1 == texels)
        #expect(try CpuBootRecord.encodeForReplay(record.scene()) == bytes)
    }

    @Test("Rust’s lazily unallocated primary glyph page normalizes to a readable empty page list")
    func emptyPrimaryAtlas() throws {
        let record = try #require(CpuBootRecord.decode(header(pages: 1) + littleEndian(0)))
        #expect(record.glyphPages.isEmpty)
        #expect(try CpuBootRecord.encodeForReplay(record.scene()) == header(pages: 0) + littleEndian(0))
    }

    @Test("Legacy Swift glyph dimensions remain readable")
    func legacyEncoding() throws {
        let bytes = header(pages: 1) + littleEndian(2) + littleEndian(2) + [1, 2, 3, 4] + littleEndian(0)
        let record = try #require(CpuBootRecord.decode(bytes))
        #expect(record.glyphPageWidth == 2 && record.glyphPageHeight == 2)
        #expect(record.glyphPages == [[1, 2, 3, 4]])
        let native = try #require(CpuBootRecord.decode(CpuBootRecord.encodeForReplay(record.scene())))
        #expect(native.glyphPages[0].count == GlyphAtlas.atlasSize * GlyphAtlas.atlasSize)
        #expect(native.glyphPages[0][GlyphAtlas.atlasSize] == 3)
    }

    @Test("Rebasing a tall atlas preserves both overflow glyphs and masks straddling the boundary")
    func stackedAtlas() throws {
        let side = GlyphAtlas.atlasSize
        let width = 8, height = side + 7
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in side - 1..<height {
            for x in 0..<width { mask[y * width + x] = UInt8((y - side + 2) * 21 + x) }
        }
        func glyph(_ dest: Float, _ source: Int) -> RenderInstance {
            RenderInstance(rect: SIMD4(dest, 0, 3, 3), fill: SIMD4(repeating: 1),
                           params: SIMD4(0, KIND_GLYPH, 0, 1), uv: SIMD4(1, Float(source), 0, 0))
        }
        let scene = CpuBootScene(instances: [glyph(0, side - 1), glyph(4, side + 1)],
                                 glyphPages: [mask], glyphPageWidth: width, glyphPageHeight: height,
                                 size: (8, 4))
        let record = try #require(CpuBootRecord.decode(CpuBootRecord.encodeForReplay(scene)))
        #expect(record.instances[1].uv.y == 1 && record.instances[1].params.z == 1)
        #expect(record.instances[0].params.z == 2)
        var original = CpuBootTarget(width: 8, height: 4)
        var decoded = CpuBootTarget(width: 8, height: 4)
        _ = try CpuBoot.paint(scene, into: &original, threads: 1)
        _ = try CpuBoot.paint(record.scene(), into: &decoded, threads: 1)
        #expect(original.pixels == decoded.pixels)
        #expect(original.pixels[0] > 0)
    }

    @Test("A custom oversized glyph remains readable in the older Swift layout")
    func oversizedMask() throws {
        let width = GlyphAtlas.atlasSize + 1
        let glyph = RenderInstance(rect: SIMD4(0, 0, Float(width), 1), params: SIMD4(0, KIND_GLYPH, 0, 1))
        let scene = CpuBootScene(instances: [glyph], glyphPages: [Array(repeating: 255, count: width)],
                                 glyphPageWidth: width, glyphPageHeight: 1, size: (width, 1))
        #expect(throws: (any Error).self) { try CpuBootRecord.encodeForReplay(scene) }
        let restored = try #require(CpuBootRecord.decode(CpuBootRecord.encode(scene)))
        #expect(restored.glyphPageWidth == width && restored.glyphPages == scene.glyphPages)
    }

    @Test("Truncated and overlarge length fields fail without allocating their claimed payload")
    func invalidLengths() {
        #expect(CpuBootRecord.decode(header(pages: .max) + littleEndian(0)) == nil)
        #expect(CpuBootRecord.decode(header(pages: 0) + littleEndian(.max)) == nil)
        #expect(CpuBootRecord.decode(header(pages: 0) + littleEndian(1) + littleEndian(.max) + littleEndian(.max)) == nil)
        #expect(CpuBootRecord.decode(header(pages: 1) + littleEndian(.max) + littleEndian(.max)) == nil)
    }
}
