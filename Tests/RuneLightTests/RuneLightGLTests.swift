#if canImport(CRuneGL) && canImport(CRuneOffscreenGL)
import CRuneGL
import CRuneOffscreenGL
import Foundation
import Rune
import RuneLight
import RuneRef
import Testing
#if canImport(Metal)
import Metal
#endif

@Suite("Portable GPU lighting")
struct RuneLightGLTests {
    private let width = 96, height = 64
    private let prims = [
        Prim.rect(32, 16, 22, 24).radius(4).raised(18).bevel(width: 2, height: 1)
            .albedo(SIMD3(0.45, 0.3, 0.1)),
        Prim.rect(8, 9, 12, 7).radius(2).emissive(SIMD3(1.6, 0.2, 0.1))
    ]
    private let light = Light.point(15, 32, 20).radius(4).range(600).intensity(0.08)

    @Test func shadowVisibilityAndRadianceMatchReferences() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        let renderer = try LightGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { renderer.close() }
        var errors = [CChar](repeating: 0, count: 512)
        let cap = errors.count
        let passes = try #require(rune_gl_pass_open(OffscreenGLContext.resolve, &errors, cap))
        defer { rune_gl_pass_close(passes) }
        let basePixels = [UInt8](repeating: 64, count: width * height * 4)
        let baseTexture = rune_gl_pass_texture(passes, RuneGLPassRGBA8, Int32(width), Int32(height), basePixels, 1, &errors, cap)
        try #require(baseTexture != 0)
        defer { rune_gl_pass_delete_texture(passes, baseTexture) }
        let scene = LightScene(prims: prims, lights: [light], settings: LightSettings(gi: nil))
        func composite(_ scene: LightScene) throws -> Frame {
            try context.withFramebuffer(width: width, height: height) {
                let rendered = try renderer.render(scene: scene, width: width, height: height,
                                                   baseTexture: baseTexture, textTexture: 0)
                #expect(rendered)
            }
        }
        let direct = try composite(scene)
        #expect(renderer.passCount == 4)
        let shadow = try #require(renderer.visibilityTexture)
        let screenVertex = """
            void main() {
                vec2 xy = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
                gl_Position = vec4(2.0 * xy - 1.0, 0.0, 1.0);
            }
            """
        let copyVisibility = """
            uniform sampler2D uTex0;
            out vec4 result;
            void main() {
                ivec2 id = ivec2(gl_FragCoord.xy);
                id.y = textureSize(uTex0, 0).y - 1 - id.y;
                result = vec4(vec3(texelFetch(uTex0, id, 0).r), 1.0);
            }
            """
        let copy = try #require(rune_gl_pass_program(passes, screenVertex, copyVisibility, &errors, cap))
        defer { rune_gl_pass_delete_program(passes, copy) }
        let visibility = try context.withFramebuffer(width: width / 2, height: height / 2) {
            let ok = rune_gl_pass_draw(passes, copy, rune_gl_pass_current_framebuffer(passes),
                                       Int32(width / 2), Int32(height / 2), [shadow], 1, nil, 0,
                                       RuneGLPassReplace, &errors, cap)
            try #require(ok != 0)
        }
        var shadowed = 0
        var lit = 0
        var errorSum: Float = 0
        for y in 2..<visibility.height-2 {
            for x in 2..<visibility.width-2 {
                let p = SIMD2(Float(x * 2 + 1), Float(y * 2 + 1))
                let distance = RuneLightCPU.primSD(prims[0], at: p)
                if abs(distance) < 3 { continue }
                let z: Float = distance < 0 ? prims[0].z.y : 0
                let expected = RuneLightCPU.estimate(prims: prims, light: light, at: SIMD3(p.x, p.y, z + 0.35))
                let actual = Float(visibility.pixel(x: x, y: y).x) / 255
                errorSum += abs(actual - expected)
                if actual < 0.1 { shadowed += 1 }
                if actual > 0.9 { lit += 1 }
            }
        }
        #expect(shadowed > 10)
        #expect(lit > 10)
        #expect(errorSum / Float(visibility.width * visibility.height) < 0.025)

        var illuminated = scene
        illuminated.settings.gi = GIParams(strength: 2.0, air: 0.6)
        let gi = try composite(illuminated)
        #expect(renderer.passCount == 10) // Same geometry reuses both the G-buffer and distance field.
        #expect(renderer.fluenceTexture != nil)
        #expect(direct.rgba != gi.rgba)
        #expect(renderer.inspect() == nil)
        renderer.inspectCascades = true
        let inspected = try composite(illuminated)
        let inspection = try #require(renderer.inspect())
        #expect(Set(inspection.merged + inspection.own).count == 2 * Int(lightCascades))
        #expect(inspection.fieldSize.0 == UInt32(width / 2))
        #expect(inspected.rgba == gi.rgba)
        #expect(renderer.passCount == 10 + Int(lightCascades))
        #if canImport(Metal)
        for (input, gl) in [(scene, direct), (illuminated, gi)] {
            let metal = try renderMetal(input, base: basePixels)
            var sum = 0
            var worst = 0
            for (a, b) in zip(gl.rgba, metal.rgba) {
                let d = abs(Int(a) - Int(b))
                sum += d
                worst = max(worst, d)
            }
            #expect(Double(sum) / Double(gl.rgba.count) < 1.5)
            #expect(worst < 25)
        }
        #endif
    }

    @Test func windowlessRendererAcceptsExternalEmissionWithoutDirectLights() throws {
        let width = 64, height = 64
        let renderer = try LightGLRenderer(width: UInt32(width), height: UInt32(height))
        defer { renderer.close() }
        var errors = [CChar](repeating: 0, count: 512)
        let capacity = errors.count
        let resources = try #require(rune_gl_pass_open(OffscreenGLContext.resolve, &errors, capacity))
        defer { rune_gl_pass_close(resources) }
        let basePixels = [UInt8](repeating: 128, count: width * height * 4)
        let bluePixels = Array(repeating: SIMD4<UInt8>(0, 0, 255, 255), count: width * height)
        let base = rune_gl_pass_texture(resources, RuneGLPassRGBA8, Int32(width), Int32(height), basePixels, 1, &errors, capacity)
        let blue = bluePixels.withUnsafeBytes { bytes in
            rune_gl_pass_texture(resources, RuneGLPassRGBA8, Int32(width), Int32(height), bytes.baseAddress, 1, &errors, capacity)
        }
        try #require(base != 0 && blue != 0)
        defer { rune_gl_pass_delete_texture(resources, base); rune_gl_pass_delete_texture(resources, blue) }
        let scene = LightScene(prims: [Prim.rect(16, 16, 32, 32).giHint()], lights: [],
                               settings: LightSettings(ambient: .zero, gi: GIParams(bounce: 0)))
        let unlit = try renderer.renderOffscreen(scene: scene, baseTexture: base)
        #expect(unlit == nil)
        #if canImport(Metal)
        let image = try renderer.renderOffscreen(scene: scene, baseTexture: base, emissionTexture: blue)
        #else
        var emitting = scene
        emitting.emission = blue
        let image = try renderer.renderOffscreen(scene: emitting, baseTexture: base)
        #endif
        let glow = try #require(image)
        let pixel = glow.pixel(x: width / 2, y: height / 2)
        #expect(Int(pixel.z) > Int(pixel.x) + 80)
    }

    @Test func refractiveGlassMatchesMetalAndCopiesUncoveredBackdrop() throws {
        // Odd dimensions exercise the first ceil-sized level and subsequent floor-sized pyramid levels.
        let w = 97, h = 65
        let context = try OffscreenGLContext()
        defer { context.close() }
        let glass = try GlassGLRenderer(resolve: OffscreenGLContext.resolve)
        defer { glass.close() }
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        let device = try #require(rune_gl_pass_open(OffscreenGLContext.resolve, &error, capacity))
        defer { rune_gl_pass_close(device) }
        var backdrop = [UInt8]()
        for y in 0..<h {
            for x in 0..<w {
                backdrop.append(contentsOf: [UInt8(x * 255 / w), UInt8(y * 255 / h), UInt8((x / 5) % 2 * 190), 255])
            }
        }
        let flipped = (0..<h).reversed().flatMap { backdrop[($0*w*4)..<(($0 + 1)*w*4)] }
        let texture = rune_gl_pass_texture(device, RuneGLPassRGBA8, Int32(w), Int32(h), flipped, 1, &error, capacity)
        try #require(texture != 0)
        defer { rune_gl_pass_delete_texture(device, texture) }
        let shapes = [Glass.rounded(19, 12, 53, 38, radius: 8).bevel(5).thickness(8).gap(5).frost(0.4)]
        func render(_ shapes: [Glass]) throws -> Frame {
            try context.withFramebuffer(width: w, height: h) {
                try glass.render(glass: shapes, width: w, height: h, backdrop: texture)
            }
        }
        let plain = try render([])
        #expect(plain.rgba == backdrop)
        let result = try render(shapes)
        #expect(plain.pixel(x: 20, y: 30) != result.pixel(x: 20, y: 30))
        #expect(plain.pixel(x: 0, y: 0) == result.pixel(x: 0, y: 0))

        #if canImport(Metal)
        let gpu = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try GlassRenderer(device: gpu, pixelFormat: .rgba8Unorm)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let input = try #require(gpu.makeTexture(descriptor: descriptor))
        let output = try #require(gpu.makeTexture(descriptor: descriptor))
        let region = MTLRegionMake2D(0, 0, w, h)
        input.replace(region: region, mipmapLevel: 0, withBytes: backdrop, bytesPerRow: w * 4)
        let queue = try #require(gpu.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        try renderer.render(commandBuffer: command, glass: shapes, backdrop: input, target: output)
        command.commit()
        command.waitUntilCompleted()
        var reference = [UInt8](repeating: 0, count: w * h * 4)
        output.getBytes(&reference, bytesPerRow: w * 4, from: region, mipmapLevel: 0)
        let delta = zip(result.rgba, reference).map { abs(Int($0) - Int($1)) }
        #expect(Double(delta.reduce(0, +)) / Double(delta.count) < 0.5)
        #expect((delta.max() ?? 0) < 14)
        #endif
    }

    #if canImport(Metal)
    private func renderMetal(_ scene: LightScene, base: [UInt8]) throws -> Frame {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try LightRenderer(device: device, width: UInt32(width), height: UInt32(height), outputFormat: .rgba8Unorm)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let baseTexture = try #require(device.makeTexture(descriptor: descriptor))
        let text = try #require(device.makeTexture(descriptor: descriptor))
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let region = MTLRegionMake2D(0, 0, width, height)
        baseTexture.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: width * 4)
        text.replace(region: region, mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: base.count), bytesPerRow: width * 4)
        let command = try #require(renderer.commandQueue.makeCommandBuffer())
        #expect(renderer.render(scene: scene, commandBuffer: command, baseTexture: baseTexture, textTexture: text, targetTexture: output))
        command.commit()
        command.waitUntilCompleted()
        var result = [UInt8](repeating: 0, count: base.count)
        output.getBytes(&result, bytesPerRow: width * 4, from: region, mipmapLevel: 0)
        return Frame(width: width, height: height, rgba: result)
    }
    #endif
}
#endif
