#if canImport(CRuneOffscreenGL)
import Rune
import RuneFX
import Testing
#if canImport(Metal)
import Metal
#endif

@Suite("RuneFX GL fluid simulation")
@MainActor
struct FxGLFireSimulationTests {
    private let viewport = SIMD2<UInt32>(64, 96)
    // Disable procedural embers so every lit pixel comes from the fluid fields.
    private let flame = Fx.fire(FireParams(height: 36, embers: 0))
        .on(FxShape.rounded(x: 8, y: 60, w: 48, h: 24, radius: 6))
        .seed(42)

    @Test func warmupContinuesAndFreezes() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        let renderer = try FxGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { renderer.close() }
        renderer.setFireSim(true)
        let initial = try renderer.renderOffscreen(viewport: viewport, layers: [flame.at(0.05)])
        let continued = try renderer.renderOffscreen(viewport: viewport, layers: [flame.at(0.10)])
        let frozen = try renderer.renderOffscreen(viewport: viewport, layers: [flame.at(0.15).reduced(true)])
        let heat = (0..<60).reduce(0) { sum, y in
            sum + (0..<64).filter { continued.pixel(x: $0, y: y).x > 8 }.count
        }
        #expect(heat > 75)
        #expect(continued.rgba != initial.rgba)
        #expect(frozen == continued)

        // A grid pruned after two empty frames must be re-created and warmed from zero.
        _ = try renderer.renderOffscreen(viewport: viewport, layers: [])
        _ = try renderer.renderOffscreen(viewport: viewport, layers: [])
        let fresh = try renderer.renderOffscreen(viewport: viewport, layers: [flame.at(0.05)])
        #expect(fresh == initial)
    }

    @Test func staleGraphCannotSampleAnotherFlame() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        let renderer = try FxGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { renderer.close() }
        renderer.setFireSim(true)
        let stale = renderer.prepare(viewport: viewport, layers: [flame])
        _ = renderer.prepare(viewport: viewport, layers: [flame.seed(99)])
        // Filter all draws so any failure here is graph validation, independent of framebuffer state.
        let otherPlace: Place = try #require(stale.prepared.first).place == .under ? .over : .under
        #expect(throws: FxGLRenderer.RenderError.self) {
            try renderer.encode(graph: stale, viewport: viewport, framebuffer: 0, place: otherPlace)
        }
    }

    #if canImport(Metal)
    @Test func simulatedFireMatchesMetalCompute() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        let gl = try FxGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { gl.close() }
        gl.setFireSim(true)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let metal = try FxRenderer(device: device, pixelFormat: .rgba8Unorm_srgb)
        metal.setFireSim(true)
        let queue = try #require(device.makeCommandQueue())
        let width = Int(viewport.x), height = Int(viewport.y)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        for time: Float in [0.05, 0.10] {
            let layer = flame.at(time)
            let actual = try gl.renderOffscreen(viewport: viewport, layers: [layer])
            _ = metal.prepare(frame: FxFrame(viewport: viewport, layers: [layer]))
            let commands = try #require(queue.makeCommandBuffer())
            #expect(try metal.simulate(commandBuffer: commands))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
            try metal.drawLayer(encoder: encoder, layer: 0)
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            #expect(commands.status == .completed)
            var reference = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&reference, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            // Half-float storage and arithmetic differences accumulate over the 72 warmup steps.
            let differences = zip(actual.rgba, reference).map { abs(Int($0) - Int($1)) }
            let mean = Double(differences.reduce(0, +)) / Double(differences.count)
            #expect(mean < 0.25)
            #expect(try #require(differences.max()) <= 8)
        }
    }
    #endif
}
#endif
