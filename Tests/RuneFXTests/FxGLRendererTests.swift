#if canImport(CRuneOffscreenGL)
import CRuneOffscreenGL
import CRuneGL
import Rune
import RuneFX
import Testing
#if canImport(Metal)
import Metal
#endif

@Suite("RuneFX OpenGL rendering")
@MainActor
struct FxGLRendererTests {
    private let viewport = SIMD2<UInt32>(96, 80)
    private let shape = FxShape.rounded(x: 22, y: 12, w: 51, h: 36, radius: 8)

    @Test func allProgramsLinkAndTableDrivenFillsRespondToChanges() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        let gl = try FxGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { gl.close() }
        try gl.warmAll()
        let mesh = Fx.fill(FillParams(.meshGradient(.dusk()))).on(shape)
        let dim = try gl.renderOffscreen(viewport: viewport, layers: [mesh.opacity(0.25)])
        let solid = try gl.renderOffscreen(viewport: viewport, layers: [mesh])
        #expect(solid.pixel(x: 40, y: 30).w > 245)
        #expect((62...65).contains(dim.pixel(x: 40, y: 30).w))
        #expect(solid.pixel(x: 40, y: 72) == .zero)
        #expect(solid.pixel(x: 27, y: 21) != solid.pixel(x: 60, y: 40))

        let slot = FxSlot().clip(SIMD4(26, 12, 45, 46))
        let clipped = try gl.renderOffscreen(viewport: viewport, layers: [mesh], slots: [slot])
        #expect(clipped.pixel(x: 32, y: 23) == solid.pixel(x: 32, y: 23))
        #expect(clipped.pixel(x: 46, y: 23) == .zero)
        let resized = try gl.renderOffscreen(viewport: SIMD2(13, 9), layers: [mesh])
        #expect(resized.width == 13 && resized.height == 9)
        #expect(resized.rgba.allSatisfy { $0 == 0 })
    }

    @Test func frostedLensSamplesAndBlursTheBackdropInDisplayOrder() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        let gl = try FxGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { gl.close() }
        var message = [CChar](repeating: 0, count: 512)
        let capacity = message.count
        let device = try #require(rune_gl_pass_open(OffscreenGLContext.resolve, &message, capacity))
        defer { rune_gl_pass_close(device) }
        let width = Int(viewport.x), height = Int(viewport.y)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = y >= height / 2 ? 255 : 0
                pixels[i + 1] = (x / 3).isMultiple(of: 2) ? 255 : 0
                pixels[i + 2] = y >= height / 2 ? 0 : 255
            }
        }
        let texture = rune_gl_pass_texture(device, RuneGLPassRGBA8, Int32(width), Int32(height),
                                           pixels, 1, &message, capacity)
        try #require(texture != 0)
        defer { rune_gl_pass_delete_texture(device, texture) }
        let area = FxShape.rounded(x: 2, y: 3, w: Float(width - 4), h: Float(height - 6), radius: 3)
        func lens(_ frost: Float) -> FxLayer {
            Fx.lens(LensParams(depth: 0, magnification: 1, frost: frost, shadow: 0, rim: 0)).on(area)
        }
        let clear = try gl.renderOffscreen(viewport: viewport, layers: [lens(0)], backdrop: texture)
        let frost = try gl.renderOffscreen(viewport: viewport, layers: [lens(0.9)], backdrop: texture)
        #expect(clear.pixel(x: 48, y: 14).x > 240)
        #expect(clear.pixel(x: 48, y: 66).z > 240)
        let crispDelta = abs(Int(clear.pixel(x: 42, y: 30).y) - Int(clear.pixel(x: 45, y: 30).y))
        let frostDelta = abs(Int(frost.pixel(x: 42, y: 30).y) - Int(frost.pixel(x: 45, y: 30).y))
        #expect(crispDelta > 180)
        #expect(frostDelta < 40)
    }

    @Test func maskMipsFilterAnOffCenterSourceAndCanBeRebuilt() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        let gl = try FxGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { gl.close() }
        var message = [CChar](repeating: 0, count: 512)
        let capacity = message.count
        let device = try #require(rune_gl_pass_open(OffscreenGLContext.resolve, &message, capacity))
        defer { rune_gl_pass_close(device) }
        var base = RuneGLPassTarget()
        let size = SIMD2<UInt32>(33, 23)
        try #require(rune_gl_pass_target(device, RuneGLPassRGBA16F, 33, 23, 1, &base, &message, capacity) != 0)
        defer { rune_gl_pass_delete_target(device, &base) }
        let pyramid = try gl.makeMaskPyramid(size: size)
        defer { gl.removeMaskPyramid(pyramid) }
        var alpha = [SIMD4<Float>](repeating: .zero, count: 33 * 23)
        for y in 12..<19 {
            for x in 5..<11 { alpha[y * 33 + x] = SIMD4(repeating: 1) }
        }
        try #require(rune_gl_pass_update_texture(device, base.texture, RuneGLPassRGBA16F,
                                                 33, 23, alpha, &message, capacity) != 0)
        try gl.buildMaskMips(pyramid, from: base.framebuffer)
        let box = FxShape.rounded(x: 0, y: 0, w: 33, h: 23, radius: 0)
        let layer = Fx.glow(GlowParams(style: .mask, radius: 5, occlusion: 1))
            .on(box).source(slot: 0, rect: box.rect)
        let frame = try gl.renderOffscreen(viewport: size, layers: [layer], sources: [pyramid])
        #expect(frame.pixel(x: 8, y: 7).w > frame.pixel(x: 28, y: 18).w)
        #expect(frame.pixel(x: 12, y: 8).w > 0)
        rune_gl_pass_clear(device, base, 0, 0, 0, 0)
        try gl.buildMaskMips(pyramid, from: base.framebuffer)
        let cleared = try gl.renderOffscreen(viewport: size, layers: [layer], sources: [pyramid])
        #expect(cleared.rgba.allSatisfy { $0 == 0 })
    }

    #if canImport(Metal)
    @Test func openGLMatchesMetalForGlowAndMeshGradient() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        let gl = try FxGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { gl.close() }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let metal = try FxRenderer(device: device, pixelFormat: .rgba8Unorm_srgb)
        for layer in [Fx.glow(GlowParams()).on(shape), Fx.fill(FillParams(.meshGradient(.dusk()))).on(shape)] {
            let gpu = try gl.renderOffscreen(viewport: viewport, layers: [layer])
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb, width: gpu.width, height: gpu.height, mipmapped: false
            )
            descriptor.usage = .renderTarget
            descriptor.storageMode = .shared
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            _ = metal.prepare(frame: FxFrame(viewport: viewport, layers: [layer]))
            let commands = try #require(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
            try metal.drawLayer(encoder: encoder, layer: 0)
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            #expect(commands.status == .completed)
            var expected = [UInt8](repeating: 0, count: gpu.rgba.count)
            texture.getBytes(&expected, bytesPerRow: gpu.width * 4,
                             from: MTLRegionMake2D(0, 0, gpu.width, gpu.height), mipmapLevel: 0)
            #expect(expected.contains(where: { $0 > 10 }))
            let maxError = zip(gpu.rgba, expected).map { abs(Int($0) - Int($1)) }.max()
            #expect(try #require(maxError) <= 3)
        }
    }
    #endif
}
#endif
