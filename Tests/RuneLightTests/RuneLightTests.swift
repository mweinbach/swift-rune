import Foundation
#if canImport(Metal)
import Metal
#endif
import Testing
@testable import RuneLight

@Suite("RuneLight Tests")
struct RuneLightTests {
    @Test func gpuStructLayoutsMatchMetalAlignment() {
        #expect(MemoryLayout<Prim>.stride == 96)
        #expect(MemoryLayout<Prim>.alignment == 16)
        #expect(MemoryLayout<Light>.stride == 64)
        #expect(MemoryLayout<Light>.alignment == 16)
        #expect(MemoryLayout<LightFrameUniforms>.stride == 144)
        #expect(MemoryLayout<LightFrameUniforms>.alignment == 16)
        #expect(MemoryLayout<CascadeUniforms>.stride == 16)
        #expect(MemoryLayout<Glass>.stride == 96)
        #expect(MemoryLayout<GlassLight>.stride == 32)
        #expect(MemoryLayout<GlassUniforms>.stride == 48)
    }

    @Test func primAndLightBuildersSetFlagsAndFields() {
        let card = Prim.rect(100, 100, 200, 120)
            .radius(16)
            .on(2)
            .raised(24)
            .bevel(width: 8, height: 4)
            .gloss(0.7, roughness: 0.25)
            .emissive(SIMD3<Float>(0.5, 0.2, 0.1))

        #expect((card.flags & flagOccluder) != 0)
        #expect((card.flags & flagRaised) != 0)
        #expect((card.flags & flagEmissive) != 0)
        #expect(card.z.x == 2)
        #expect(card.z.y == 26)
        #expect(card.z.z == 8)
        #expect(card.z.w == 4)

        let hint = Prim.rect(0, 0, 50, 50).giHint()
        #expect((hint.flags & flagGIHint) != 0)

        let lt = Light.point(300, 200, 150)
            .color(SIMD3<Float>(1.0, 0.5, 0.25))
            .intensity(2.0)
            .shafts(0.4)
            .scaled(0.5)
        #expect(abs(lt.color.x - 1.0) < 1e-5)
        #expect(abs(lt.extra.x - 0.2) < 1e-5)

        let gl = GlassLight.fromEmitter(card, z: 30, gain: 2.0)
        #expect(gl != nil)
        #expect(abs(gl!.color.x - 1.0) < 1e-5)
    }

    @Test func sdfAndSoftShadowMath() {
        let card = Prim.rect(100, 100, 100, 100).radius(10).raised(40)
        #expect(RuneLightCPU.primSD(card, at: SIMD2<Float>(150, 150)) < 0.0)
        #expect(RuneLightCPU.primSD(card, at: SIMD2<Float>(50, 50)) > 0.0)

        let light = Light.point(50, 150, 25).radius(8).softness(1.0)
        // Unoccluded side (same side as light)
        let lit = RuneLightCPU.estimate(prims: [card], light: light, at: SIMD3<Float>(70, 150, 0))
        let gtLit = RuneLightCPU.groundTruth(prims: [card], light: light, at: SIMD3<Float>(70, 150, 0), samples: 8)
        #expect(lit > 0.95)
        #expect(gtLit > 0.95)

        // Occluded side (behind raised card)
        let shadowed = RuneLightCPU.estimate(prims: [card], light: light, at: SIMD3<Float>(220, 150, 0))
        let gtShadowed = RuneLightCPU.groundTruth(prims: [card], light: light, at: SIMD3<Float>(220, 150, 0), samples: 8)
        #expect(shadowed < 0.15)
        #expect(gtShadowed < 0.15)
    }

    #if canImport(Metal)
    @Test func activeLightingDetectionAndUniforms() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try LightRenderer(width: 640, height: 360)
        let flat = Prim.rect(10, 10, 100, 50)
        let emptyScene = LightScene(prims: [flat], lights: [])
        #expect(!renderer.hasActiveLighting(emptyScene))

        let litScene = LightScene(prims: [flat], lights: [Light.point(100, 100, 100)])
        #expect(renderer.hasActiveLighting(litScene))
        let u = renderer.buildFrameUniforms(scene: litScene)
        #expect(u.sf.x == 640)
        #expect(u.sf.y == 360)
        #expect(u.counts.x == 1)
        #expect(u.counts.y == 1)
    }

    @Test func metalLightingAndGlassPipelinesCompileOnHostDevice() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let lightRenderer = try LightRenderer(width: 320, height: 240)
        let glassRenderer = try GlassRenderer()
        #expect(lightRenderer.fieldSize == (160, 120))
        #expect(glassRenderer.device.name.isEmpty == false)
    }
    #endif
}
