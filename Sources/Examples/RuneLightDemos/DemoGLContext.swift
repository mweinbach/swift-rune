#if canImport(CRuneOffscreenGL) && canImport(CRuneGL)
import CRuneGL
import Rune
import RuneLight

final class DemoGLContext: LightDemoContext {
    var ts: TextSystem { layers.ts }
    private let context: OffscreenGLContext
    private let layers: LightGLLayers
    private let finish: @convention(c) () -> Void
    private let passes: OpaquePointer
    private var output = RuneGLPassTarget()

    init() throws {
        context = try OffscreenGLContext()
        let resolve = OffscreenGLContext.resolve
        layers = try LightGLLayers(resolve: resolve)
        guard let address = resolve("glFinish") else {
            throw LightRendererError.shaderCompileFailed("OpenGL is missing glFinish")
        }
        finish = unsafeBitCast(address, to: (@convention(c) () -> Void).self)
        var error = [CChar](repeating: 0, count: 512)
        let size = error.count
        guard let passes = rune_gl_pass_open(resolve, &error, size) else { throw Self.failure(error) }
        self.passes = passes
        DisplayGpuAdapter(backend: OffscreenGLContext.isGLES ? .openGLES : .openGL,
                          device: layers.adapterName).reportIfRequested()
    }

    private static func failure(_ message: [CChar]) -> LightRendererError {
        .shaderCompileFailed(String(decoding: message.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self))
    }

    func enableTimings() {
        _ = layers.light.enableTimings(resolve: OffscreenGLContext.resolve)
    }

    var gpuMilliseconds: Double? { layers.light.readTimings(wait: true)?.total }

    func drawUI(base: [DemoUIInst], text: [DemoUIInst], clear: Color) throws {
        try context.makeCurrent()
        try layers.drawUI(base: base, text: text, clear: clear, width: demoW, height: demoH)
    }

    func lightFrame(prims: [Prim], lights: [Light], settings: LightSettings, read: Bool) throws -> [UInt8]? {
        let scene = LightScene(prims: prims, lights: lights, settings: settings)
        if read {
            return try context.withFramebuffer(width: demoW, height: demoH) {
                try layers.composite(scene: scene)
            }.rgba
        }
        try context.makeCurrent()
        if output.framebuffer == 0 {
            var error = [CChar](repeating: 0, count: 512)
            let size = error.count
            guard rune_gl_pass_target(passes, RuneGLPassRGBA8, Int32(demoW), Int32(demoH), 0,
                                      &output, &error, size) != 0 else { throw Self.failure(error) }
        }
        try layers.composite(scene: scene, framebuffer: output.framebuffer)
        finish()
        return nil
    }

    func visibility() throws -> DemoVisibility {
        guard let texture = layers.light.visibilityTexture else {
            throw LightRendererError.shaderCompileFailed("Render a lighting frame before reading visibility")
        }
        let vertex = """
        void main() {
            vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
            gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
        }
        """
        // Read the first light channel into two RGBA8 bytes; GLES does not guarantee float FBO readback.
        let fragment = """
        uniform sampler2D uTex0;
        out vec4 outColor;
        void main() {
            float visibility = texelFetch(uTex0, ivec2(gl_FragCoord.xy), 0).r;
            uint bits = uint(round(clamp(visibility, 0.0, 1.0) * 65535.0));
            outColor = vec4(float(bits >> 8), float(bits & 255u), 0.0, 255.0) / 255.0;
        }
        """
        try context.makeCurrent()
        var error = [CChar](repeating: 0, count: 512)
        let size = error.count
        guard let copy = rune_gl_pass_program(passes, vertex, fragment, &error, size) else { throw Self.failure(error) }
        defer { rune_gl_pass_delete_program(passes, copy) }
        let width = (demoW + 1) / 2, height = (demoH + 1) / 2
        let pixels = try context.withFramebuffer(width: width, height: height) {
            let target = rune_gl_pass_current_framebuffer(passes)
            guard rune_gl_pass_draw(passes, copy, target, Int32(width), Int32(height), [texture], 1,
                                    nil, 0, RuneGLPassReplace, &error, size) != 0 else { throw Self.failure(error) }
        }.rgba
        return DemoVisibility(width: width, height: height) { x, y in
            // The shadow shader stores Rune's y=0 at GL row zero, while Frame is top-down.
            let idx = ((height - 1 - y) * width + x) * 4
            return Float(Int(pixels[idx]) * 256 + Int(pixels[idx + 1])) / 65535
        }
    }

    deinit {
        if (try? context.makeCurrent()) != nil {
            rune_gl_pass_delete_target(passes, &output)
            rune_gl_pass_close(passes)
            layers.close()
        } else {
            rune_gl_pass_abandon(passes)
            layers.abandon()
        }
        context.close()
    }
}
#endif
