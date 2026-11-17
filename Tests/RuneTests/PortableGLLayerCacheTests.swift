#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import Testing
import RuneMotion
@testable import Rune

@MainActor
@Suite("GL retained layer ownership")
struct PortableGLLayerCacheTests {
    private func checkStaleFrame(_ frame: RenderFrame, renderer: PortableGLRenderer) throws {
        do {
            try renderer.draw(frame)
            Issue.record("Submitted a frame missing a required resident texture")
        } catch let error as PortableGLRenderer.RenderError {
            #expect(error.description.contains("was evicted"))
        }
    }

    @Test("A new GL renderer rebuilds omitted children and teardown only releases its own entries")
    func changeRenderer() throws {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(48, 32), pixelScale: 1) { _, _ in
            el().sizeFull().child(el().key("panel").size(24, 16).cache().bg(.white))
        }
        try withTestGLTarget { original, capture in
            let first = original.frame(runtime, at: 0)
            let baseline = try capture(first.width, first.height) { try original.draw(first) }
            #expect(baseline.pixel(x: 8, y: 8) == SIMD4(repeating: 255))
            let initial = original.layerStats()
            #expect(initial.cachedLayers == 1 && initial.targets == 1)
            #expect(initial.allocations == 1 && initial.bytes == initial.cachedBytes)
            let retained = original.frame(runtime, at: 0.1)
            #expect(!retained.elidedLayers.isEmpty)
            let hit = try capture(retained.width, retained.height) { try original.draw(retained) }
            #expect(hit == baseline)
            #expect(original.layerStats().hits > 0)

            try withTestGLTarget { replacement, resized in
                try checkStaleFrame(retained, renderer: replacement)
                let rebuilt = replacement.frame(runtime, at: 0.2)
                #expect(rebuilt.elidedLayers.isEmpty)
                let restored = try resized(rebuilt.width, rebuilt.height) { try replacement.draw(rebuilt) }
                #expect(restored == baseline)
                #expect(!runtime.residentCacheTracker.isEmpty)
            }
            #expect(runtime.residentCacheTracker.isEmpty)
            let reclaimed = original.frame(runtime, at: 0.3)
            #expect(!reclaimed.elidedLayers.isEmpty)
            original.setLayerCacheBudget(0)
            #expect(runtime.residentCacheTracker.isEmpty)
            try checkStaleFrame(reclaimed, renderer: original)
            let uncached = original.frame(runtime, at: 0.4)
            let raster = try capture(uncached.width, uncached.height) { try original.draw(uncached) }
            #expect(raster == baseline)
            let transient = original.layerStats()
            #expect(transient.cachedBytes == 0)
            #expect(transient.targets == 1 && transient.bytes > 0)
        }
    }
}
#endif
