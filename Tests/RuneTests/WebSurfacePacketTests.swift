import Foundation
import Testing
@testable import Rune

@Suite struct WebSurfacePacketTests {
    @Test func placementsShareOneUploadAcrossFramesAndLoseItWhenRemoved() throws {
        let surface = NativeSurface()
        let placed = surface.placed(SurfacePlace(anchor: (.end, .start), unscaled: true))
        let planes = [Data([16, 20, 40, 235]), Data([127, 130])]
        let image = try ByteFrame(width: 2, height: 2, format: .nv12Video, color: .bt709, planes: planes)
        try surface.pushBytes(image, frameId: 7)
        let bounds = SIMD4<Float>(0, 0, 14, 10)
        let draws = [surface, placed].enumerated().map { index, view in
            SurfaceDraw(surface: view, fit: .fit, beforeInstance: UInt32(index), rect: bounds, clip: bounds)
        }
        let first = try WebSurfacePacket(draws, srgbBlend: false, size: SIMD2(14, 10))
        #expect(first.count == 2)
        #expect(first.bytes.count == 248 * 2 + 6)
        #expect(first.bytes.subdata(in: 248..<254) == planes[0] + planes[1])
        first.bytes.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            #expect(bytes.loadUnaligned(fromByteOffset: 32, as: UInt32.self) == 4)
            #expect(bytes.loadUnaligned(fromByteOffset: 36, as: UInt32.self) == 2)
            #expect(bytes.loadUnaligned(fromByteOffset: 254, as: UInt32.self) == 1)
            #expect(bytes.loadUnaligned(fromByteOffset: 254 + 32, as: UInt32.self) == 0)
            #expect(bytes.loadUnaligned(fromByteOffset: 254 + 40 + 32, as: Float.self) == 12)
        }
        let next = try WebSurfacePacket(draws, srgbBlend: false, size: SIMD2(14, 10), previous: first.next)
        #expect(next.bytes.count == 248 * 2)
        // A repeated frame ID can contain new pixels. Rune tracks publication revisions independently.
        try surface.pushBytes(image, frameId: 7)
        let updated = try WebSurfacePacket(draws, srgbBlend: false, size: SIMD2(14, 10), previous: next.next)
        #expect(updated.bytes.count == first.bytes.count)
        let absent = try WebSurfacePacket([], srgbBlend: false, size: SIMD2(14, 10), previous: updated.next)
        #expect(absent.bytes.isEmpty)
        let reappeared = try WebSurfacePacket(draws, srgbBlend: false, size: SIMD2(14, 10), previous: absent.next)
        #expect(reappeared.bytes.count == first.bytes.count)
    }

    @Test func submittedSurfacesKeepTheirPresentedFrameIDsUntilTheFenceSignals() throws {
        let surface = NativeSurface()
        let image = try ByteFrame(width: 1, height: 1, format: .rgba, color: .srgb, planes: [Data([1, 2, 3, 255])])
        try surface.pushBytes(image, frameId: 123)
        let rect = SIMD4<Float>(0, 0, 4, 4)
        let draw = SurfaceDraw(surface: surface, fit: .fit, beforeInstance: 0, rect: rect, clip: rect)
        var cache = try WebSurfacePacket([draw, draw], srgbBlend: false, size: SIMD2(4, 4)).next
        let timings = WebSurfaceTimings()
        let first = timings.submit(cache.takeParticipants())
        #expect(first != 0)
        #expect(timings.submit(cache.takeParticipants()) == 0)
        #expect(surface.counts().0 == 2 && surface.counts().1 == 0)
        try surface.pushBytes(image, frameId: 124)
        timings.complete(first, success: true)
        timings.complete(first, success: true)
        #expect(surface.counts().1 == 2)
        #expect(surface.timing()?.frameId == 123)
        #expect(surface.timing()?.completedAt != nil)
        let second = timings.submit([(surface, 124)])
        timings.complete(second, success: false)
        #expect(surface.counts().0 == 3 && surface.counts().1 == 2)
        #expect(surface.timing()?.frameId == 124)
        #expect(surface.timing()?.completedAt == nil)
    }
}
