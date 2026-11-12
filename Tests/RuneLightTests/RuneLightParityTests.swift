#if canImport(Metal)
import Metal
#endif
import Rune
import Testing
@testable import RuneLight

@Suite("RuneLight Parity Tests")
struct RuneLightParityTests {
    @Test func primFromRuneConversionsMapGeometryAndRadii() {
        let motionRect = MotionRect(left: 10, top: 20, right: 130, bottom: 80)
        let corners = Corners(4, 8, 12, 16)
        let p1 = Prim.fromRune(rect: motionRect, corners: corners, scale: 2.0)
        #expect(p1.rect == SIMD4<Float>(20, 40, 240, 120))
        #expect(p1.radii == SIMD4<Float>(8, 16, 24, 32))

        let layout = ComputedLayout(localRect: MotionRect(left: 5, top: 15, right: 85, bottom: 55))
        let p2 = Prim.fromRune(layout: layout, corners: .all(6), scale: 1.0)
        #expect(p2.rect == SIMD4<Float>(5, 15, 80, 40))
        #expect(p2.radii == SIMD4<Float>(6, 6, 6, 6))

        struct Dummy {}
        let el: El<Dummy> = El<Dummy>().rounded(10)
        let p3 = Prim.fromRune(element: el, rect: motionRect, scale: 1.0)
        #expect(p3.rect == SIMD4<Float>(10, 20, 120, 60))
        #expect(p3.radii == SIMD4<Float>(10, 10, 10, 10))
    }

    #if canImport(Metal)
    @Test func rendererVisibilityInspectAndTimings() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try LightRenderer(device: device, width: 160, height: 120)
        #expect(renderer.visibilityTexture.width == 80)
        #expect(renderer.visibilityTexture.height == 60)

        let inspect = renderer.inspect()
        #expect(inspect.field.width == 80)
        #expect(inspect.emission.width == inspect.giSize.0)
        #expect(inspect.occluders.width == inspect.giSize.0)
        #expect(inspect.fluence.width == inspect.giSize.0)
        #expect(!inspect.merged.isEmpty)
        #expect(!inspect.own.isEmpty)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: renderer.outputFormat,
            width: 160,
            height: 120,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        let baseTex = try #require(device.makeTexture(descriptor: desc))
        let textTex = try #require(device.makeTexture(descriptor: desc))
        let targetTex = try #require(device.makeTexture(descriptor: desc))

        let queue = try #require(device.makeCommandQueue())
        let cmd = try #require(queue.makeCommandBuffer())
        let scene = LightScene(
            prims: [Prim.rect(20, 20, 40, 40).raised(16)],
            lights: [Light.point(10, 40, 30)]
        )
        let rendered = renderer.render(
            scene: scene,
            commandBuffer: cmd,
            baseTexture: baseTex,
            textTexture: textTex,
            targetTexture: targetTex
        )
        #expect(rendered)
        cmd.commit()
        cmd.waitUntilCompleted()

        let timings = try #require(renderer.readTimings(commandBuffer: cmd))
        #expect(timings.total >= 0)
        #expect(timings.raster >= 0)
    }
    #endif
}
