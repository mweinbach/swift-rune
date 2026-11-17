#if canImport(CRuneGL) && canImport(CRuneOffscreenGL)
import CRuneGL
import CRuneOffscreenGL
import Rune
import RuneLight
import Testing

@Suite("Portable GPU lighting timings")
struct RuneLightTimingTests {
    @Test func queuedSamplesTrackStagesAcrossGeometryCacheHits() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        let renderer = try LightGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { renderer.close() }
        guard renderer.enableTimings(resolve: OffscreenGLContext.resolve) else { return }

        var error = [CChar](repeating: 0, count: 256)
        let capacity = error.count
        let passes = try #require(rune_gl_pass_open(OffscreenGLContext.resolve, &error, capacity))
        defer { rune_gl_pass_close(passes) }
        let width = 128, height = 96
        var source = RuneGLPassTarget()
        try #require(rune_gl_pass_target(passes, RuneGLPassRGBA8, Int32(width), Int32(height), 1,
                                         &source, &error, capacity) != 0)
        defer { rune_gl_pass_delete_target(passes, &source) }
        rune_gl_pass_clear(passes, source, 0.2, 0.1, 0.4, 1)
        let prims = [Prim.rect(20, 30, 17, 11).emissive(SIMD3(1, 0.8, 0.5))]
        let lights = [Light.point(39, 36, 24)]
        let direct = LightScene(prims: prims, lights: lights)
        let bounced = LightScene(prims: prims, lights: lights, settings: LightSettings(gi: GIParams()))
        #expect(renderer.readTimings() == nil)
        for scene in [direct, bounced, direct] {
            _ = try context.withFramebuffer(width: width, height: height) {
                try renderer.render(scene: scene, width: width, height: height, baseTexture: source.texture,
                                    textTexture: 0)
            }
        }
        var measuredMilliseconds = 0.0
        for expectedGI in [false, true, false] {
            let sample = try #require(renderer.readTimings(wait: true))
            let stages = sample.raster + sample.field + sample.shadows + sample.gi
            #expect(abs(sample.total - stages) < 0.000001)
            measuredMilliseconds += sample.total
            if !expectedGI { #expect(sample.gi == 0) }
        }
        // Timer resolution is implementation dependent; individual short intervals can round to zero.
        #expect(measuredMilliseconds > 0)
        #expect(renderer.readTimings() == nil)
    }
}
#endif
