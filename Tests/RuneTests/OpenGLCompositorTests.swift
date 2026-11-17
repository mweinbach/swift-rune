#if canImport(CRuneGL) && canImport(CRuneOffscreenGL)
import CRuneGL
import RuneRef
import Testing
@testable import Rune
#if canImport(Metal)
import Metal
#endif

@MainActor
@Suite("Native GL app compositor")
struct OpenGLCompositorTests {
    private final class TestCompositor: Compositor {
        typealias State = Int
        let renderBody: (CompositorFrame<Int>) -> Void
        let drawsOwnContent: Bool

        init(drawsOwnContent: Bool = true, _ body: @escaping (CompositorFrame<Int>) -> Void) {
            self.drawsOwnContent = drawsOwnContent
            renderBody = body
        }
        func render(frame: CompositorFrame<Int>) { renderBody(frame) }
    }

    private func markedUI() -> Runtime<Int> {
        Runtime(state: 0, viewport: Vec2(32, 32), pixelScale: 1) { _, _ in
            el().size(32, 32).bg(Color(r: 1, g: 0, b: 0, a: 1))
                .child(el().absolute(x: 4, y: 4).size(16, 16).effect(70_000).effectBackdrop(true))
                .child(el().absolute(x: 12, y: 4).size(8, 16).bg(Color(r: 0, g: 0, b: 1, a: 1)))
        }
    }

    @Test("A shader samples the backdrop and draws only inside its authored slot, before later siblings")
    func orderedEffects() throws {
        try withTestGLTarget { renderer, capture in
            let runtime = markedUI()
            let scene = runtime.renderFrame(at: 0)
            var calls = 0
            var held: CompositorFrame<Int>?
            var caught: (any Error)?
            let compositor = TestCompositor { frame in
                held = frame
                #expect(frame.openGL != nil)
                frame.drawUI()
                do {
                    try frame.drawUI(withEffects: { pass in
                        calls += 1
                        #expect(throws: CompositorError.recursiveUIDraw) {
                            try frame.drawUI(withEffects: { _ in })
                        }
                        #expect(pass.site.mark == 70_000)
                        #expect(pass.site.index == 0)
                        let target = try #require(pass.openGL)
                        let source = try #require(target.backdropTexture)
                        var error = [CChar](repeating: 0, count: 512)
                        let device = try #require(rune_gl_pass_open(target.resolve, &error, 512))
                        defer { rune_gl_pass_close(device) }
                        let vert = """
                            void main() {
                                vec2 p = vec2(gl_VertexID & 1, gl_VertexID >> 1);
                                gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
                            }
                            """
                        let frag = """
                            uniform sampler2D uTex0;
                            out vec4 color;
                            void main() { color = texelFetch(uTex0, ivec2(gl_FragCoord.xy), 0).grba; }
                            """
                        let program = try #require(rune_gl_pass_program(device, vert, frag, &error, 512))
                        defer { rune_gl_pass_delete_program(device, program) }
                        let success = rune_gl_pass_draw(device, program, target.framebuffer,
                                                        Int32(target.pixelSize.width), Int32(target.pixelSize.height),
                                                        [source], 1, nil, 0, RuneGLPassReplace, &error, 512)
                        #expect(success != 0)
                    })
                } catch { caught = error }
            }
            let pixels = try capture(32, 32) {
                let count = try renderer.draw(scene, compositor: AnyCompositor(compositor), runtime: runtime, at: 0)
                #expect(count == 2)
            }
            if let caught { throw caught }
            #expect(calls == 1)
            #expect(pixels.pixel(x: 2, y: 8) == SIMD4<UInt8>(255, 0, 0, 255))
            #expect(pixels.pixel(x: 8, y: 8) == SIMD4<UInt8>(0, 255, 0, 255))
            #expect(pixels.pixel(x: 16, y: 8) == SIMD4<UInt8>(0, 0, 255, 255))
            #expect(held?.openGL == nil)
            #expect(throws: CompositorError.expiredFrame) { try held?.drawUI(withEffects: { _ in }) }

            let fallback = TestCompositor(drawsOwnContent: false) { _ in }
            let plain = try capture(32, 32) {
                let count = try renderer.draw(scene, compositor: AnyCompositor(fallback), runtime: runtime, at: 1)
                #expect(count == 1)
            }
            #expect(plain.pixel(x: 8, y: 8) == SIMD4<UInt8>(255, 0, 0, 255))
        }
    }

    #if canImport(Metal)
    @Test("The same compositor callback samples the Metal target in painter order")
    func orderedMetalEffects() throws {
        let runtime = markedUI()
        let frame = runtime.renderFrame(at: 0)
        let gpu = try OffscreenGPURenderer()
        var caught: (any Error)?
        let compositor = TestCompositor { context in
            do {
                let device = try #require(context.device)
                let shaders = try device.makeLibrary(source: """
                    #include <metal_stdlib>
                    using namespace metal;
                    vertex float4 compositorVertex(uint id [[vertex_id]]) {
                        float2 uv = float2(id & 1, id >> 1);
                        return float4(uv * 2 - 1, 0, 1);
                    }
                    fragment float4 swapRG(float4 xy [[position]], texture2d<float, access::read> color [[texture(0)]]) {
                        return color.read(uint2(xy.xy)).grba;
                    }
                    """, options: nil)
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = shaders.makeFunction(name: "compositorVertex")
                desc.fragmentFunction = shaders.makeFunction(name: "swapRG")
                desc.colorAttachments[0].pixelFormat = context.pixelFormat
                let pipeline = try device.makeRenderPipelineState(descriptor: desc)
                try context.drawUI(withEffects: { pass in
                    #expect(throws: CompositorError.recursiveUIDraw) {
                        try context.drawUI(withEffects: { _ in })
                    }
                    #expect(pass.site.mark == 70_000)
                    let encoder = try #require(pass.metalEncoder)
                    let backdrop = try #require(pass.site.backdrop)
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentTexture(backdrop, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                })
            } catch { caught = error }
        }
        let (pixels, draws) = try gpu.renderOffscreen(frame, compositor: AnyCompositor(compositor),
                                                      runtime: runtime, at: 0, dt: 0)
        if let caught { throw caught }
        #expect(draws == 1)
        #expect(pixels.pixel(x: 2, y: 8) == SIMD4<UInt8>(255, 0, 0, 255))
        #expect(pixels.pixel(x: 8, y: 8) == SIMD4<UInt8>(0, 255, 0, 255))
        #expect(pixels.pixel(x: 16, y: 8) == SIMD4<UInt8>(0, 0, 255, 255))
    }
    #endif
}
#endif
