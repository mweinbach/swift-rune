import Foundation
import Testing
@testable import Rune

@Suite struct WindowsVideoLayerGeometryTests {
    private func sample() throws -> NativeSurfaceVideoFrame {
        let bytes = try ByteFrame(width: 4, height: 2, format: .nv12Video, color: .bt709,
                                  planes: [Data(repeating: 128, count: 8), Data(repeating: 128, count: 4)])
        return NativeSurfaceVideoFrame(id: 1, size: (4, 2), format: .nv12Video, color: .bt709,
                                       orient: .up, source: .bytes(bytes))
    }

    @Test func letterboxAndClippedCoverKeepTheirSourceGeometry() throws {
        let picture = try sample()
        var draw = SurfaceDraw(surface: NativeSurface(), fit: .fit, beforeInstance: 0,
                               rect: SIMD4(16, 10, 60, 60), clip: NO_CLIP)
        var frame = RenderFrame(width: 160, height: 125, surfaces: [draw])
        let fit = try #require(WindowsVideoLayerGeometry.destination(frame, index: 0, picture: picture))
        #expect(fit.x == 16 && fit.y == 25 && fit.width == 60 && fit.height == 30)
        draw.fit = .fill
        draw.clip = SIMD4(20, 16, 70, 55)
        frame.surfaces = [draw]
        let cover = try #require(WindowsVideoLayerGeometry.destination(frame, index: 0, picture: picture))
        #expect(cover.x == -14 && cover.y == 10 && cover.width == 120 && cover.height == 60)
        #expect(cover.clip == SIMD4(34, 6, 84, 45))
        draw.opacity = 0.75
        frame.surfaces = [draw]
        #expect(WindowsVideoLayerGeometry.destination(frame, index: 0, picture: picture) == nil)
        draw.opacity = 1
        draw.clipFade.w = Float(8).bitPattern
        frame.surfaces = [draw]
        #expect(WindowsVideoLayerGeometry.destination(frame, index: 0, picture: picture) == nil)
        draw.clipFade = .zero
        draw.rect.x += 0.25
        frame.surfaces = [draw]
        #expect(WindowsVideoLayerGeometry.destination(frame, index: 0, picture: picture) == nil)
    }

    @Test func painterOrderAndIsolationReturnPicturesToTheUI() throws {
        let picture = try sample()
        var draw = SurfaceDraw(surface: NativeSurface(), fit: .stretch, beforeInstance: 1,
                               rect: SIMD4(10, 10, 64, 32), clip: NO_CLIP)
        let behind = RenderInstance(rect: SIMD4(10, 10, 64, 32))
        let beside = RenderInstance(rect: SIMD4(90, 10, 8, 8))
        var frame = RenderFrame(width: 180, height: 80, instances: [behind, beside], surfaces: [draw])
        #expect(WindowsVideoLayerGeometry.destination(frame, index: 0, picture: picture) != nil)
        frame.instances.append(RenderInstance(rect: SIMD4(15, 15, 2, 2)))
        #expect(WindowsVideoLayerGeometry.destination(frame, index: 0, picture: picture) == nil)
        frame.instances.removeLast()
        frame.instances[1].params = SIMD4(0, KIND_SHADOW, 8, 0)
        #expect(WindowsVideoLayerGeometry.destination(frame, index: 0, picture: picture) == nil)
        frame.instances = [.beginLayer(bounds: SIMD4(0, 0, 80, 80), clip: NO_CLIP), .endLayer()]
        #expect(WindowsVideoLayerGeometry.destination(frame, index: 0, picture: picture) == nil)
        draw.beforeInstance = 0
        frame.instances.removeAll()
        var other = draw
        other.surface = NativeSurface()
        frame.surfaces = [draw, other]
        #expect(WindowsVideoLayerGeometry.destination(frame, index: 0, picture: picture) == nil)
        #expect(WindowsVideoLayerGeometry.destination(frame, index: 1, picture: picture) != nil)
    }
}
