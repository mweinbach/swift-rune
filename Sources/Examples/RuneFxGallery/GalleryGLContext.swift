#if canImport(CRuneGL) && (os(macOS) || os(Linux) || os(Windows))
import CRuneGL
import Foundation
import Rune
import RuneFX

/// Composites the gallery’s UI, captured backdrop and effect slots in the authored paint order.
final class GalleryGLContext: GalleryRendering {
    let w: Int
    let h: Int
    private var viewport: SIMD2<UInt32> { SIMD2(UInt32(w), UInt32(h)) }
    private let context: OffscreenGLContext
    private let fx: FxGLRenderer
    private let atlas = TextAtlas()
    private var device: OpaquePointer?
    private var ui: OpaquePointer?
    private var resolve: OpaquePointer?
    private var scene = RuneGLPassTarget()
    private var backdrop = RuneGLPassTarget()
    private var mask = RuneGLPassTarget()
    private var source = RuneGLPassTarget()
    private var glyphs: UInt32 = 0
    private var pyramid: UInt32 = 0

    init(w: Int, h: Int) throws {
        self.w = w
        self.h = h
        context = try OffscreenGLContext()
        fx = try FxGLRenderer(resolve: OffscreenGLContext.resolve, options: FxOptions(dither: false))
        device = try Self.handle { rune_gl_pass_open(OffscreenGLContext.resolve, $0, $1) }
        do {
            ui = try Self.handle { rune_gl_pass_program(device, Self.layout + Self.uiVertex, Self.layout + Self.uiFragment, $0, $1) }
            resolve = try Self.handle { rune_gl_pass_program(device, Self.quadVertex, Self.resolveFragment, $0, $1) }
            try allocate(&scene, w, h)
            try allocate(&backdrop, w, h)
            try allocate(&mask, w, h)
            pyramid = try fx.makeMaskPyramid(size: viewport)
            DisplayGpuAdapter(backend: OffscreenGLContext.isGLES ? .openGLES : .openGL, device: fx.adapter).reportIfRequested()
        } catch {
            close()
            throw error
        }
    }

    private static func handle(_ body: (UnsafeMutablePointer<CChar>, Int) -> OpaquePointer?) throws -> OpaquePointer {
        var error = [CChar](repeating: 0, count: 1024)
        let size = error.count
        guard let result = body(&error, size) else { throw failure(error) }
        return result
    }

    private static func check(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var error = [CChar](repeating: 0, count: 1024)
        let size = error.count
        if body(&error, size) == 0 { throw failure(error) }
    }

    private static func failure(_ message: [CChar]) -> GalleryError {
        GalleryError(String(decoding: message.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    private func allocate(_ target: inout RuneGLPassTarget, _ width: Int, _ height: Int) throws {
        try Self.check { rune_gl_pass_target(device, RuneGLPassRGBA16F, Int32(width), Int32(height), 1, &target, $0, $1) }
    }

    private func uploadGlyphs() throws {
        guard atlas.dirty || glyphs == 0 else { return }
        let dim = Int32(galleryAtlasSize)
        try atlas.data.withUnsafeBytes { bytes in
            if glyphs != 0 {
                try Self.check { rune_gl_pass_update_texture(device, glyphs, RuneGLPassR8, dim, dim, bytes.baseAddress, $0, $1) }
            } else {
                var error = [CChar](repeating: 0, count: 1024)
                let size = error.count
                glyphs = rune_gl_pass_texture(device, RuneGLPassR8, dim, dim, bytes.baseAddress, 1, &error, size)
                if glyphs == 0 { throw Self.failure(error) }
            }
        }
        atlas.dirty = false
    }

    private func drawUI(_ instances: ArraySlice<UiInst>, to target: RuneGLPassTarget) throws {
        for instance in instances {
            try withUnsafeBytes(of: instance) { uniforms in
                try Self.check {
                    rune_gl_pass_draw(device, ui, target.framebuffer, target.width, target.height, [glyphs], 1,
                                      uniforms.baseAddress, uniforms.count, RuneGLPassPremultipliedOver, $0, $1)
                }
            }
        }
    }

    private func resizeSource(_ width: Int, _ height: Int) throws {
        guard source.width != width || source.height != height else { return }
        var next = RuneGLPassTarget()
        try allocate(&next, width, height)
        rune_gl_pass_delete_target(device, &source)
        source = next
    }

    func render(name: String, t: Float, reduced: Bool) throws -> [UInt8] {
        try context.makeCurrent()
        atlas.beginScene(name)
        let builder = GalleryBuilder(atlas: atlas, t: t, reduced: reduced)
        buildGalleryScene(name: name, into: builder)
        try atlas.checkCapacity()
        try uploadGlyphs()
        var textures = [pyramid]
        if !builder.mask.isEmpty {
            rune_gl_pass_clear(device, mask, 0, 0, 0, 0)
            try drawUI(builder.mask[...], to: mask)
            try fx.buildMaskMips(pyramid, from: mask.framebuffer)
        }
        if let rect = builder.srcRect {
            try resizeSource(max(1, Int((rect.w + 2 * gallerySrcPad) * galleryS)),
                             max(1, Int((rect.h + 2 * gallerySrcPad) * galleryS)))
            rune_gl_pass_clear(device, source, 0, 0, 0, 0)
            try drawUI(builder.src[...], to: source)
            textures.append(source.texture)
        }
        rune_gl_pass_clear(device, scene, 0, 0, 0, 1)
        let graph = fx.prepare(viewport: viewport, layers: builder.layers, scale: galleryS, slots: builder.slots, hasBackdrop: true)
        for op in builder.ops {
            switch op {
            case .ui(let range):
                try drawUI(builder.ui[range], to: scene)
            case .fx(let index):
                try fx.encode(graph: graph, viewport: viewport, framebuffer: scene.framebuffer,
                              backdrop: backdrop.texture, sources: textures, layer: index)
            case .backdrop:
                try Self.check { rune_gl_pass_copy_mip(device, scene, backdrop.texture, 0, $0, $1) }
            }
        }
        return try context.withFramebuffer(width: w, height: h) {
            let target = rune_gl_pass_current_framebuffer(device)
            try Self.check {
                rune_gl_pass_draw(device, resolve, target, Int32(w), Int32(h), [scene.texture], 1,
                                  nil, 0, RuneGLPassReplace, $0, $1)
            }
        }.rgba
    }

    func timings() throws -> String {
        try context.makeCurrent()
        guard let address = OffscreenGLContext.resolve("glFinish") else {
            throw GalleryError("OpenGL driver lacks glFinish for synchronized effect timings")
        }
        let finish = unsafeBitCast(address, to: (@convention(c) () -> Void).self)
        try resizeSource(808, 408)
        rune_gl_pass_clear(device, mask, 0, 0, 0, 0)
        try fx.buildMaskMips(pyramid, from: mask.framebuffer)
        rune_gl_pass_clear(device, source, 0, 0, 0, 0)
        rune_gl_pass_clear(device, backdrop, 0, 0, 0, 1)
        let clock = ContinuousClock()
        let gpuTimer = GalleryGLTimer()
        let timeSource = gpuTimer == nil ? "synchronized wall" : "GPU"
        var out = "| effect | covered px (2x) | reads/px | noise/px | backdrop | \(timeSource) ms per draw (median; 10 draws/batch) |\n|---|---:|---:|---:|:-:|---:|\n"
        for (name, layer) in timingLayers() {
            let graph = fx.prepare(viewport: viewport, layers: [layer], scale: galleryS, hasBackdrop: true)
            var samples: [Double] = []
            // Match the Metal benchmark's four warm-up and twelve measured batches.
            for batch in 0..<16 {
                rune_gl_pass_clear(device, scene, 0, 0, 0, 1)
                finish()
                func drawBatch() throws {
                    for _ in 0..<timingDraws {
                        try fx.encode(graph: graph, viewport: viewport, framebuffer: scene.framebuffer,
                                      backdrop: backdrop.texture, sources: [pyramid, source.texture])
                    }
                }
                let elapsed: Double?
                if let gpuTimer {
                    elapsed = try gpuTimer.milliseconds(drawBatch)
                } else {
                    let time = try clock.measure { try drawBatch(); finish() }.components
                    elapsed = Double(time.seconds) * 1000 + Double(time.attoseconds) / 1e15
                }
                if batch >= 4, let elapsed { samples.append(elapsed / Double(timingDraws)) }
            }
            let cost = layer.fx.cost
            let measured = samples.isEmpty ? "unavailable" : String(format: "%.3f", samples.sorted()[samples.count / 2])
            out += "| \(name) | \(graph.stats.pixels) | \(cost.samples) | \(cost.alu) | \(cost.backdrop ? "yes" : "") | \(measured) |\n"
        }
        return out
    }

    private func close() {
        guard let device else { return }
        try? context.makeCurrent()
        rune_gl_pass_delete_texture(device, glyphs)
        rune_gl_pass_delete_target(device, &source)
        rune_gl_pass_delete_target(device, &mask)
        rune_gl_pass_delete_target(device, &backdrop)
        rune_gl_pass_delete_target(device, &scene)
        if let resolve { rune_gl_pass_delete_program(device, resolve) }
        if let ui { rune_gl_pass_delete_program(device, ui) }
        fx.close()
        rune_gl_pass_close(device)
        self.device = nil
        context.close()
    }

    deinit { close() }

    private static let layout = """
    layout(std140) uniform RunePass { vec4 rect, p, fill, fill2, border, uv, vp; } u;

    """

    private static let uiVertex = """
    out vec2 px;
    void main() {
        vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
        float margin = u.p.z > 1.5 ? u.p.w * 3.5 + 1.0 : 1.0;
        px = u.rect.xy - margin + (u.rect.zw + 2.0 * margin) * corner;
        vec2 ndc = px / u.vp.xy * 2.0 - 1.0;
        gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    }
    """

    private static let uiFragment = """
    in vec2 px;
    out vec4 color;
    uniform sampler2D uTex0;
    void main() {
        vec2 halfSize = u.rect.zw * 0.5;
        float r = clamp(u.p.x, 0.0, min(halfSize.x, halfSize.y));
        vec2 q = abs(px - u.rect.xy - halfSize) - halfSize + r;
        float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
        int kind = int(u.p.z + 0.5);
        if (kind == 1) {
            vec2 uv = mix(u.uv.xy, u.uv.zw, (px - u.rect.xy) / u.rect.zw);
            color = u.fill * pow(textureLod(uTex0, uv, 0.0).r, 0.85);
        } else if (kind == 2) {
            float x = d / (max(u.p.w, 0.1) * 1.41421);
            float x2 = x * x;
            float erf = sign(x) * sqrt(1.0 - exp(-x2 * (1.2732395 + 0.147 * x2) / (1.0 + 0.147 * x2)));
            color = u.fill * (0.5 - 0.5 * erf);
        } else {
            float cov = clamp(0.5 - d, 0.0, 1.0);
            float band = u.p.y > 0.0 ? cov - clamp(0.5 - d - u.p.y, 0.0, 1.0) : 0.0;
            float t = clamp((px.y - u.rect.y) / max(u.rect.w, 1.0), 0.0, 1.0);
            color = mix(u.fill, u.fill2, t) * cov * (1.0 - u.border.a * band) + u.border * band;
        }
    }
    """

    private static let quadVertex = """
    void main() {
        vec2 p = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
        gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    }
    """

    private static let resolveFragment = """
    uniform sampler2D uTex0;
    out vec4 color;
    uint pcg(uint v) {
        uint s = v * 747796405u + 2891336453u;
        uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
        return (w >> 22u) ^ w;
    }
    float noise(uint v) { return float(pcg(v) >> 8u) / 16777216.0; }
    void main() {
        ivec2 texel = ivec2(gl_FragCoord.xy);
        vec3 c = clamp(texelFetch(uTex0, texel, 0).rgb, 0.0, 1.0);
        uvec2 p = uvec2(texel.x, textureSize(uTex0, 0).y - 1 - texel.y);
        float n = noise(p.x + pcg(p.y)) + noise(p.x * 7919u + pcg(p.y + 104729u)) - 1.0;
        vec3 srgb = mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, 12.92 * c, lessThanEqual(c, vec3(0.0031308)));
        color = vec4(clamp(srgb + n / 255.0, 0.0, 1.0), 1.0);
    }
    """
}
#endif
