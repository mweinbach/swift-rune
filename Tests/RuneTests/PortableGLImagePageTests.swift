#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import RuneRef
import Testing
@testable import Rune

@MainActor
@Suite("Native GL atlas pages")
struct PortableGLImagePageTests {
    private func solid(_ rgba: [UInt8], width: Int = 1, height: Int = 1) -> RGBA8Atlas {
        RGBA8Atlas(width: width, height: height, texels: Array(repeating: rgba, count: width * height).flatMap { $0 })
    }

    private func image(_ page: Float, _ x: Float, width: Float = 4, uv: SIMD4<Float> = SIMD4(0, 0, 1, 1)) -> RenderInstance {
        RenderInstance(rect: SIMD4(x, 0, width, 4), fill: SIMD4(repeating: 1),
                       params: SIMD4(page, KIND_IMAGE, 0, 0), uv: uv)
    }

    @Test func interleavedPagesKeepTheirLocalCoordinatesAcrossLayersAndEdits() throws {
        let page = solid([255, 0, 0, 255], width: 5, height: 3)
        let other = solid([0, 255, 0, 255], width: 7, height: 3)
        var frame = RenderFrame(width: 16, height: 4, imagePages: [page, other], instances: [
            image(1, 0, uv: SIMD4(2, 1, 1, 1)), image(0, 4),
            .beginLayer(bounds: SIMD4(8, 0, 8, 4), clip: NO_CLIP),
            image(1, 8, width: 8, uv: SIMD4(2, 1, 1, 1)), image(0, 12), .endLayer()
        ])
        try withTestGLTarget { renderer, capture in
            func pixels() throws -> Frame {
                try capture(16, 4) { try renderer.draw(frame) }
            }
            let first = try pixels()
            #expect(first.pixel(x: 2, y: 2) == SIMD4(0, 255, 0, 255))
            #expect(first.pixel(x: 6, y: 2) == SIMD4(255, 0, 0, 255))
            #expect(first.pixel(x: 10, y: 2) == first.pixel(x: 2, y: 2))
            #expect(first.pixel(x: 14, y: 2) == first.pixel(x: 6, y: 2))
            #expect(try pixels() == first)
            // Public frame producers may edit an atlas without a revision counter.
            frame.imagePages[1].texels.replaceSubrange((9 * 4)..<(10 * 4), with: [0, 0, 255, 255])
            let patched = try pixels()
            #expect(patched.pixel(x: 2, y: 2) == SIMD4(0, 0, 255, 255))
            #expect(patched.pixel(x: 10, y: 2) == patched.pixel(x: 2, y: 2))
            #expect(patched.pixel(x: 6, y: 2) == first.pixel(x: 6, y: 2))
            frame.imagePages[1] = solid([255, 255, 0, 255], width: 3, height: 2)
            #expect(try pixels().pixel(x: 2, y: 2) == SIMD4(255, 255, 0, 255))
            frame.imagePages[1].texels = []
            #expect(try pixels().pixel(x: 10, y: 2) == SIMD4(0, 0, 0, 255))
            frame.imagePages.removeLast()
            #expect(try pixels().pixel(x: 2, y: 2) == SIMD4(0, 0, 0, 255))
            frame.imagePages.append(other)
            #expect(try pixels() == first)
            frame.imagePages = []
            frame.images = solid([0, 255, 255, 255])
            let fallback = try pixels()
            #expect(fallback.pixel(x: 6, y: 2) == SIMD4(0, 255, 255, 255))
            #expect(fallback.pixel(x: 2, y: 2) == SIMD4(0, 0, 0, 255))
        }
    }

    @Test func glyphAndImagePagesRetainIndependentBindings() throws {
        func glyph(_ page: Float, _ x: Float) -> RenderInstance {
            RenderInstance(rect: SIMD4(x, 0, 4, 4), fill: SIMD4(1, 1, 1, 1),
                           params: SIMD4(0, KIND_GLYPH, page, 1), uv: SIMD4(0, 0, 1, 1))
        }
        let covered = R8Atlas(width: 1, height: 1, texels: [255])
        let empty = R8Atlas(width: 1, height: 1, texels: [0])
        var frame = RenderFrame(width: 20, height: 4, glyphPages: [covered, empty], imagePages: [
            solid([255, 0, 0, 255]), solid([0, 255, 0, 255])
        ], instances: [
            glyph(0, 0), image(1, 4), glyph(1, 8), image(0, 12), glyph(9, 16)
        ])
        try withTestGLTarget { renderer, capture in
            func draw() throws -> Frame { try capture(20, 4) { try renderer.draw(frame) } }
            let initial = try draw()
            #expect(initial.pixel(x: 2, y: 2) == SIMD4(255, 255, 255, 255))
            #expect(initial.pixel(x: 6, y: 2) == SIMD4(0, 255, 0, 255))
            #expect(initial.pixel(x: 10, y: 2) == SIMD4(0, 0, 0, 255))
            #expect(initial.pixel(x: 14, y: 2) == SIMD4(255, 0, 0, 255))
            #expect(initial.pixel(x: 18, y: 2) == initial.pixel(x: 2, y: 2))
            // A dirty receipt is trusted only if its source revision is the resident one.
            frame.glyphPageRevisions = [100, 101]
            #expect(try draw() == initial)
            frame.glyphPages[1] = covered
            frame.glyphPageRevisions = [100, 102]
            frame.glyphPagePatches = [nil, ImageAtlasPatch(fromRevision: 101, edges: SIMD4(0, 0, 1, 1))]
            #expect(try draw().pixel(x: 10, y: 2) == initial.pixel(x: 2, y: 2))
            renderer.giveBackForWindowRest(all: true)
            #expect(try draw().pixel(x: 10, y: 2) == initial.pixel(x: 2, y: 2))
        }
    }

    @Test func olderSingleAtlasPacketsKeepMissingPagesTransparent() throws {
        let palette = [solid([255, 0, 0, 255]), solid([0, 255, 0, 255])]
        let frame = RenderFrame(width: 12, height: 4, imagePages: palette, instances: [
            image(0.75, 0), image(1, 4), image(7, 8)
        ])
        try withTestGLTarget { renderer, capture in
            let native = try capture(12, 4) { try renderer.draw(frame) }
            let packed = try frame.packedForLegacyWebPacket()
            let legacy = try capture(12, 4) { try renderer.draw(packed) }
            #expect(native == legacy)
            #expect(native.pixel(x: 2, y: 2) == SIMD4(255, 0, 0, 255))
            #expect(native.pixel(x: 6, y: 2) == SIMD4(0, 255, 0, 255))
            #expect(native.pixel(x: 10, y: 2) == SIMD4(0, 0, 0, 255))
        }
    }

    @Test func pageLimitsApplyToEachTexture() throws {
        // Repacking these two legal pages into rows exceeded the driver's height limit.
        // Their combined CPU image data is only 128 KiB on a 16,384-texel device.
        try withTestGLTarget { renderer, capture in
            typealias GetInteger = @convention(c) (UInt32, UnsafeMutablePointer<Int32>) -> Void
            let entry = try #require(OffscreenGLContext.resolve("glGetIntegerv"))
            var driverLimit: Int32 = 0
            unsafeBitCast(entry, to: GetInteger.self)(0x0D33, &driverLimit)
            let limit = min(16_384, Int(driverLimit))
            let wide = solid([255, 0, 0, 255], width: limit)
            let tall = solid([0, 255, 0, 255], height: limit)
            let frame = RenderFrame(width: 8, height: 4, imagePages: [wide, tall], instances: [
                image(0, 0), image(1, 4)
            ])
            let rendered = try capture(8, 4) { try renderer.draw(frame) }
            #expect(rendered.pixel(x: 2, y: 2) == SIMD4(255, 0, 0, 255))
            #expect(rendered.pixel(x: 6, y: 2) == SIMD4(0, 255, 0, 255))
        }
    }
}
#endif
