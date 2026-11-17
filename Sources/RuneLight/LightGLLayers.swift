import Rune

// Shared GPU instance format for the lighting examples' base and glyph layers.
package struct LightUIInstance: Sendable {
    package var rect, radii, fill, border, params, uv, vp: SIMD4<Float>
    package init(rect: SIMD4<Float>, radii: SIMD4<Float>, fill: SIMD4<Float>, border: SIMD4<Float>,
                 params: SIMD4<Float>, uv: SIMD4<Float>, vp: SIMD4<Float>) {
        self.rect = rect
        self.radii = radii
        self.fill = fill
        self.border = border
        self.params = params
        self.uv = uv
        self.vp = vp
    }
}

#if canImport(CRuneGL)
import CRuneGL
import Foundation

package final class LightGLLayers {
    package let ts = TextSystem()
    package let light: LightGLRenderer
    package var adapterName: String { light.adapterName }
    private var device: OpaquePointer?
    private var ui: OpaquePointer?
    private var base = RuneGLPassTarget()
    private var text = RuneGLPassTarget()
    private var instanceTexture: UInt32 = 0
    private var instanceCapacity = 0
    private var atlas: UInt32 = 0
    private var generation: UInt64?

    package init(resolve: RuneGLResolve) throws {
        light = try LightGLRenderer(resolve: resolve)
        var error = [CChar](repeating: 0, count: 2048)
        let capacity = error.count
        guard let device = rune_gl_pass_open(resolve, &error, capacity) else { throw Self.failure(error) }
        self.device = device
        let block = """
        struct Instance { vec4 rect, radii, fill, border, params, uv, vp; };
        uniform sampler2D uTex1;
        Instance fetchInstance(int id) {
            return Instance(texelFetch(uTex1, ivec2(0, id), 0), texelFetch(uTex1, ivec2(1, id), 0),
                            texelFetch(uTex1, ivec2(2, id), 0), texelFetch(uTex1, ivec2(3, id), 0),
                            texelFetch(uTex1, ivec2(4, id), 0), texelFetch(uTex1, ivec2(5, id), 0),
                            texelFetch(uTex1, ivec2(6, id), 0));
        }
        """
        let vert = block + """
        out vec2 pixel;
        flat out int id;
        void main() {
            id = gl_InstanceID;
            Instance p = fetchInstance(id);
            vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
            pixel = p.rect.xy - 1.0 + corner * (p.rect.zw + 2.0);
            vec2 ndc = pixel / p.vp.xy * 2.0 - 1.0;
            gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
        }
        """
        let frag = block + """
        uniform sampler2D uTex0;
        in vec2 pixel;
        flat in int id;
        out vec4 color;
        void main() {
            Instance p = fetchInstance(id);
            vec2 size = p.rect.zw * 0.5;
            vec2 q = pixel - p.rect.xy - size;
            if (p.params.y > 0.5) {
                vec2 t = (pixel - p.rect.xy) / max(p.rect.zw, vec2(1e-4));
                if (any(lessThan(t, vec2(0.0))) || any(greaterThan(t, vec2(1.0)))) discard;
                color = p.fill * texture(uTex0, mix(p.uv.xy, p.uv.zw, t)).r;
            } else {
                float r = q.x < 0.0 ? (q.y < 0.0 ? p.radii.x : p.radii.w) : (q.y < 0.0 ? p.radii.y : p.radii.z);
                r = clamp(r, 0.0, min(size.x, size.y));
                vec2 k = abs(q) - size + r;
                float d = length(max(k, 0.0)) + min(max(k.x, k.y), 0.0) - r;
                float cov = clamp(0.5 - d, 0.0, 1.0);
                float band = cov - clamp(0.5 - d - p.params.x, 0.0, 1.0);
                color = p.fill * cov * (1.0 - p.border.a * band) + p.border * band;
            }
        }
        """
        guard let ui = rune_gl_pass_program(device, vert, frag, &error, capacity) else {
            close(); throw Self.failure(error)
        }
        self.ui = ui
    }

    private func resize(_ w: Int32, _ h: Int32) throws {
        guard base.width != w || base.height != h else { return }
        var error = [CChar](repeating: 0, count: 512)
        let size = error.count
        var nextBase = RuneGLPassTarget(), nextText = RuneGLPassTarget()
        guard rune_gl_pass_target(device, RuneGLPassRGBA16F, w, h, 1, &nextBase, &error, size) != 0 else { throw Self.failure(error) }
        guard rune_gl_pass_target(device, RuneGLPassRGBA16F, w, h, 1, &nextText, &error, size) != 0 else {
            rune_gl_pass_delete_target(device, &nextBase)
            throw Self.failure(error)
        }
        rune_gl_pass_delete_target(device, &base)
        rune_gl_pass_delete_target(device, &text)
        base = nextBase
        text = nextText
    }

    private static func failure(_ bytes: [CChar]) -> LightRendererError {
        .shaderCompileFailed(String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    package func drawUI(base: [LightUIInstance], text: [LightUIInstance], clear: Color, width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw LightRendererError.shaderCompileFailed("Invalid light UI target dimensions") }
        try resize(Int32(width), Int32(height))
        let atlasGeneration = UInt64(ts.glyphAtlas.generation)
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        if generation != atlasGeneration {
            let glyphs = ts.glyphAtlas.atlas
            let texture = glyphs.texels.withUnsafeBytes { pixels in
                rune_gl_pass_texture(device, RuneGLPassR8, Int32(glyphs.width), Int32(glyphs.height), pixels.baseAddress, 1, &error, capacity)
            }
            guard texture != 0 else { throw Self.failure(error) }
            rune_gl_pass_delete_texture(device, atlas)
            atlas = texture
            generation = atlasGeneration
        }
        let required = max(base.count, text.count)
        if required > instanceCapacity {
            guard let height = Int32(exactly: required) else {
                throw LightRendererError.shaderCompileFailed("The demo has too many UI instances")
            }
            let texture = rune_gl_pass_texture(device, RuneGLPassRGBA32F, 7, height, nil, 0, &error, capacity)
            guard texture != 0 else { throw Self.failure(error) }
            rune_gl_pass_delete_texture(device, instanceTexture)
            instanceTexture = texture
            instanceCapacity = required
        }
        func draw(_ insts: [LightUIInstance], _ dst: RuneGLPassTarget, _ color: SIMD4<Float>) throws {
            rune_gl_pass_clear(device, dst, color.x, color.y, color.z, color.w)
            guard !insts.isEmpty else { return }
            let count = Int32(insts.count)
            let uploaded = insts.withUnsafeBytes { raw in
                rune_gl_pass_update_texture(device, instanceTexture, RuneGLPassRGBA32F, 7, count,
                                            raw.baseAddress, &error, capacity)
            }
            guard uploaded != 0 else { throw Self.failure(error) }
            let ok = rune_gl_pass_draw_instances(device, ui, dst.framebuffer, dst.width, dst.height,
                                                 [atlas, instanceTexture], 2, nil, 0, RuneGLPassPremultipliedOver,
                                                 count, &error, capacity)
            if ok == 0 { throw Self.failure(error) }
        }
        try draw(base, self.base, SIMD4(clear.r, clear.g, clear.b, 1))
        try draw(text, self.text, .zero)
    }

    package func composite(scene: LightScene, framebuffer: UInt32? = nil) throws {
        try light.render(scene: scene, width: Int(base.width), height: Int(base.height),
                         baseTexture: base.texture, textTexture: text.texture, framebuffer: framebuffer)
    }

    package func close() {
        if let device {
            rune_gl_pass_delete_texture(device, atlas)
            rune_gl_pass_delete_texture(device, instanceTexture)
            rune_gl_pass_delete_target(device, &base)
            rune_gl_pass_delete_target(device, &text)
            rune_gl_pass_delete_program(device, ui)
            rune_gl_pass_close(device)
            self.device = nil
        }
        light.close()
    }

    /// Release wrappers without deleting GL objects after the borrowed context is lost.
    package func abandon() {
        if let device {
            rune_gl_pass_delete_program(nil, ui)
            rune_gl_pass_abandon(device)
            self.device = nil
        }
        light.abandon()
    }

    deinit { close() }
}
#endif
