#if canImport(Metal)
import Metal
import RuneMotion
import Testing
@testable import Rune

@MainActor
@Suite("Metal retained layer ownership")
struct MetalLayerCacheHandoffTests {
    private func panel(image tile: RGBA8Atlas? = nil) -> Runtime<Void> {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(32, 16), pixelScale: 1) { _, _ in
            let panel: El<Void> = el().key("panel").size(16, 12).cache().bg(Color(r: 0, g: 1, b: 0, a: 1))
            let root = row().sizeFull().child(panel)
            guard let tile else { return root }
            return root.child(image(tile).key("image").size(16, 12).cache())
        }
        runtime.clearColor = .black
        return runtime
    }

    private func expectMissingLayer(_ frame: RenderFrame, on renderer: MetalRenderer) throws {
        let omitted = try #require(frame.elidedLayers.first)
        do {
            _ = try renderer.renderOffscreen(frame)
            Issue.record("Submitted an incomplete frame for layer \(omitted.node)")
        } catch MetalRenderer.RendererError.missingCachedLayer(let node) {
            #expect(node == omitted.node)
        }
    }

    @Test("A new Metal renderer rejects an incomplete frame and its predecessor can safely release its cache")
    func changeRenderer() throws {
        let runtime = panel()
        let replacement = try MetalRenderer()
        let baseline: Frame
        do {
            let original = try MetalRenderer()
            baseline = try original.renderOffscreen(original.frame(runtime, at: 0))
            #expect(baseline.pixel(x: 8, y: 6) == SIMD4(0, 255, 0, 255))
            #expect(baseline.pixel(x: 24, y: 6) == SIMD4(0, 0, 0, 255))

            let cached = original.frame(runtime, at: 0.1)
            try #require(cached.elidedLayers.count == 1)
            try expectMissingLayer(cached, on: replacement)
            let rebuilt = replacement.frame(runtime, at: 0.2)
            #expect(rebuilt.elidedLayers.isEmpty)
            let restored = try replacement.renderOffscreen(rebuilt)
            #expect(restored == baseline)
            original.giveBack(all: true)
        }
        let cached = runtime.renderFrame(at: 0.3)
        #expect(cached.elidedLayers.count == 1)
        let restored = try replacement.renderOffscreen(cached)
        #expect(restored == baseline)
        replacement.giveBack(all: true)
        #expect(runtime.residentCacheTracker.isEmpty)
        try expectMissingLayer(cached, on: replacement)
    }

    @Test("Identical layer keys and signatures in separate runtimes have independent residency")
    func changeRuntime() throws {
        // The solid panel has the same signature across runtimes. The neighboring
        // image occupies the same atlas rectangle but has its own content version.
        let first = panel(image: RGBA8Atlas(width: 1, height: 1, texels: [255, 0, 0, 255]))
        let second = panel(image: RGBA8Atlas(width: 1, height: 1, texels: [0, 0, 255, 255]))
        let renderer = try MetalRenderer()
        let baseline = try renderer.renderOffscreen(renderer.frame(first, at: 0))
        #expect(baseline.pixel(x: 8, y: 6) == SIMD4(0, 255, 0, 255))
        #expect(baseline.pixel(x: 24, y: 6) == SIMD4(255, 0, 0, 255))
        let firstCached = renderer.frame(first, at: 0.1)
        try #require(firstCached.elidedLayers.count == 2)

        let next = renderer.frame(second, at: 0.2)
        #expect(next.elidedLayers.isEmpty)
        #expect(first.residentCacheTracker.isEmpty)
        let hits = renderer.layerStats().hits
        let rendered = try renderer.renderOffscreen(next)
        #expect(rendered.pixel(x: 8, y: 6) == SIMD4(0, 255, 0, 255))
        #expect(rendered.pixel(x: 24, y: 6) == SIMD4(0, 0, 255, 255))
        #expect(renderer.layerStats().hits == hits)
        let secondCached = renderer.frame(second, at: 0.3)
        try #require(secondCached.elidedLayers.count == 2)
        let firstPanel = firstCached.elidedLayers[0], secondPanel = secondCached.elidedLayers[0]
        #expect(firstPanel.node == secondPanel.node && firstPanel.signature == secondPanel.signature)
        let firstImage = firstCached.elidedLayers[1], secondImage = secondCached.elidedLayers[1]
        #expect(firstImage.node == secondImage.node && firstImage.signature != secondImage.signature)
        try expectMissingLayer(firstCached, on: renderer)
        let rebuilt = renderer.frame(first, at: 0.4)
        #expect(rebuilt.elidedLayers.isEmpty)
        let returned = try renderer.renderOffscreen(rebuilt)
        #expect(returned == baseline)
    }

    @Test("A prepared layer becomes resident after its first draw")
    func prepareWithoutDraw() throws {
        let runtime = panel()
        let renderer = try MetalRenderer()
        let frame = renderer.frame(runtime, at: 0)
        renderer.prepare(frame: frame, viewport: (frame.width, frame.height))
        #expect(runtime.renderFrame(at: 0.1).elidedLayers.isEmpty)
        let pixels = try renderer.renderOffscreen(frame)
        #expect(pixels.pixel(x: 8, y: 6) == SIMD4(0, 255, 0, 255))
        #expect(runtime.renderFrame(at: 0.2).elidedLayers.count == 1)
    }

    @Test("Releasing the active Metal renderer restores the runtime's draw commands")
    func releaseActiveRenderer() throws {
        let runtime = panel()
        do {
            let renderer = try MetalRenderer()
            _ = try renderer.renderOffscreen(renderer.frame(runtime, at: 0))
            #expect(renderer.frame(runtime, at: 0.1).elidedLayers.count == 1)
        }
        #expect(runtime.residentCacheTracker.isEmpty)
        #expect(runtime.renderFrame(at: 0.2).elidedLayers.isEmpty)
    }

    @Test("An uncommitted Metal draw keeps its own pixels when later frames finish first")
    func pendingCommandBuffer() throws {
        let runtime = Runtime<Bool>(state: false, viewport: Vec2(32, 16), pixelScale: 1) { green, _ in
            let color = green ? Color(r: 0, g: 1, b: 0, a: 1) : Color(r: 1, g: 0, b: 0, a: 1)
            return el().sizeFull().child(el().key("panel").size(16, 12).cache().bg(color))
        }
        runtime.clearColor = .black
        let renderer = try MetalRenderer()
        let initial = renderer.frame(runtime, at: 0)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: initial.width, height: initial.height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let delayed = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.drawRange(frame: initial, into: target, commandBuffer: delayed)
        let red = try renderer.renderOffscreen(renderer.frame(runtime, at: 0.1))
        #expect(red.pixel(x: 8, y: 6) == SIMD4(255, 0, 0, 255))
        runtime.state = true
        runtime.invalidate(at: 0.2)
        let green = try renderer.renderOffscreen(renderer.frame(runtime, at: 1.2))
        #expect(green.pixel(x: 8, y: 6) == SIMD4(0, 255, 0, 255))

        delayed.commit()
        delayed.waitUntilCompleted()
        try #require(delayed.status == .completed)
        var delayedRGBA = [UInt8](repeating: 0, count: red.rgba.count)
        target.getBytes(&delayedRGBA, bytesPerRow: target.width * 4,
                        from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        for pixel in stride(from: 0, to: delayedRGBA.count, by: 4) {
            delayedRGBA.swapAt(pixel, pixel + 2)
        }
        #expect(delayedRGBA == red.rgba)
        let latest = try renderer.renderOffscreen(renderer.frame(runtime, at: 1.3))
        #expect(latest == green)
    }

    #if os(macOS) && canImport(CRuneOffscreenGL)
    @Test("Switching from OpenGL to Metal and back draws each renderer's resident texture")
    func switchBackends() throws {
        let runtime = panel()
        let metal = try MetalRenderer()
        try withTestGLTarget { gl, capture in
            let full = gl.frame(runtime, at: 0)
            let baseline = try capture(full.width, full.height) { try gl.draw(full) }
            #expect(baseline.pixel(x: 8, y: 6) == SIMD4(0, 255, 0, 255))
            let fromGL = gl.frame(runtime, at: 0.1)
            try #require(fromGL.elidedLayers.count == 1)

            let metalFrame = metal.frame(runtime, at: 0.2)
            #expect(metalFrame.elidedLayers.isEmpty)
            let native = try metal.renderOffscreen(metalFrame)
            #expect(native == baseline)
            #expect(metal.frame(runtime, at: 0.3).elidedLayers.count == 1)

            let reacquired = gl.frame(runtime, at: 0.4)
            #expect(reacquired.elidedLayers.count == 1)
            metal.setLayerCacheBudget(0)
            #expect(runtime.renderFrame(at: 0.5).elidedLayers.count == 1)
            let returned = try capture(reacquired.width, reacquired.height) { try gl.draw(reacquired) }
            #expect(returned == baseline)
        }
        #expect(runtime.residentCacheTracker.isEmpty)
    }
    #endif
}
#endif
