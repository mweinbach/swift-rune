#if canImport(CRuneGL) && canImport(CRuneOffscreenGL)
import CRuneGL
import Foundation
import RuneRef

/// Offscreen production draw path for comparing retained GPU springs with CPU-updated instances.
package final class GLSpringFrameRenderer {
    private let context: OffscreenGLContext
    private var renderer: PortableGLRenderer?
    private var passes: OpaquePointer?
    private var tracksTexture: UInt32 = 0
    private var idsTexture: UInt32 = 0
    private var instanceCount = 0
    private var retainedInstances: [RenderInstance]?
    private var settleTime = 0.0
    private var sampleTime = SIMD2<Float>.zero

    package init() throws {
        context = try OffscreenGLContext()
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        guard let device = rune_gl_pass_open(OffscreenGLContext.resolve, &error, capacity) else {
            throw OffscreenRenderError.unavailable(Self.message(error))
        }
        passes = device
    }

    // Three RGBA32F texels per track: coefficients, rates/goal/kind, and split start/duration.
    // The differential run uses this same function to capture position and velocity from the GPU.
    package static let sampleGLSL = """
    float runeSpringExp(float x) {
        if (x < -87.0) return 0.0;
        float k = roundEven(x * 1.4426950408889634);
        float r = (x - k * 0.69314575) - k * 0.0000014286068;
        float r2 = r * r;
        float b = 0.5 + r / 6.0;
        float c = 1.0 / 24.0 + r / 120.0;
        float p = (1.0 + r) + r2 * (b + r2 * (c + r2 / 720.0));
        return p * uintBitsToFloat(uint(int(k) + 127) << 23u);
    }

    vec2 runeSpringSample(vec4 c, vec4 ratesGoalKind, vec4 startDuration, vec2 time) {
        int kind = int(ratesGoalKind.w);
        float goal = ratesGoalKind.z;
        float whole = float(int(time.x) - int(startDuration.x));
        float t = max(whole + (time.y - startDuration.y), 0.0);
        if (kind == 0 || t >= startDuration.z) return vec2(goal, 0.0);
        if (kind == 1) {
            float e = exp(-ratesGoalKind.x * t);
            float co = cos(ratesGoalKind.y * t);
            float si = sin(ratesGoalKind.y * t);
            return vec2(goal + e * (c.x * co + c.y * si), e * (c.z * co + c.w * si));
        }
        if (kind == 2) {
            float e = exp(-ratesGoalKind.x * t);
            return vec2(goal + (c.x + c.y * t) * e, (c.z + c.w * t) * e);
        }
        float e1 = runeSpringExp(c.z * t);
        float e2 = runeSpringExp(c.w * t);
        return vec2(goal + c.x * e1 + c.y * e2, c.x * c.z * e1 + c.y * c.w * e2);
    }
    """

    private static let vertexPrefix = """
    #define RUNE_FRAME_SPRINGS
    uniform sampler2D uSpringTracks;
    uniform sampler2D uSpringIDs;
    uniform vec2 uSpringTime;
    uniform int uSpringFirst;
    vec4 fetchSpringTexel(sampler2D table, int index) {
        int width = textureSize(table, 0).x;
        return texelFetch(table, ivec2(index % width, index / width), 0);
    }
    \(sampleGLSL)
    float sampleSpringTrack(int index) {
        return runeSpringSample(fetchSpringTexel(uSpringTracks, index),
                                fetchSpringTexel(uSpringTracks, index + 1),
                                fetchSpringTexel(uSpringTracks, index + 2), uSpringTime).x;
    }

    """

    package func withSprings(nodes: [GPUSpringNode], ids: [UInt32], timeSeconds: Double) throws {
        try context.makeCurrent()
        guard let passes, nodes.count <= 1 << 24,
              ids.count <= Int(Int32.max), ids.allSatisfy({ Int($0) < nodes.count }) else {
            throw OffscreenRenderError.capture("Invalid spring nodes or per-instance indices")
        }
        var coefficients = [SIMD4<Float>]()
        coefficients.reserveCapacity(nodes.count * 9)
        for node in nodes {
            for track in [node.x, node.y, node.opacity] {
                coefficients.append(track.abcd)
                coefficients.append(SIMD4(track.rates.x, track.rates.y, track.goal, Float(track.kind)))
                coefficients.append(SIMD4(track.start.x, track.start.y, track.duration, 0))
            }
        }
        let tracks = try Self.texture(passes, format: RuneGLPassRGBA32F, texels: coefficients, padding: .zero)
        let indices: UInt32
        do {
            indices = try Self.texture(passes, format: RuneGLPassR32F, texels: ids.map { Float($0) }, padding: 0)
        } catch {
            rune_gl_pass_delete_texture(passes, tracks)
            throw error
        }
        if tracksTexture == 0 {
            // A renderer that already drew static frames has the ordinary vertex program.
            renderer?.close()
            renderer = nil
        }
        rune_gl_pass_delete_texture(passes, tracksTexture)
        rune_gl_pass_delete_texture(passes, idsTexture)
        tracksTexture = tracks
        idsTexture = indices
        instanceCount = ids.count
        settleTime = nodes.reduce(0) { max($0, $1.settleAt()) }
        setSpringTime(timeSeconds)
    }

    private static func texture<T>(_ passes: OpaquePointer, format: RuneGLPassFormat, texels: [T], padding: T) throws -> UInt32 {
        let width = max(1, Int(ceil(sqrt(Double(texels.count)))))
        let height = max(1, (texels.count + width - 1) / width)
        var padded = texels
        padded.append(contentsOf: repeatElement(padding, count: width * height - texels.count))
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        let texture = padded.withUnsafeBytes {
            rune_gl_pass_texture(passes, format, Int32(width), Int32(height), $0.baseAddress, 0, &error, capacity)
        }
        guard texture != 0 else { throw OffscreenRenderError.capture(message(error)) }
        return texture
    }

    private static func message(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    package func setSpringTime(_ time: Double) {
        sampleTime = splitSpringTime(time)
    }

    package func springsAnimating(at time: Double) -> Bool { time < settleTime }

    private func paint(_ frame: RenderFrame) throws {
        guard passes != nil else { throw OffscreenRenderError.capture("Spring renderer is closed") }
        if tracksTexture != 0 && frame.instances.count > instanceCount {
            throw OffscreenRenderError.capture("Missing spring index for a render instance")
        }
        if renderer == nil {
            let springs = tracksTexture != 0
            renderer = try PortableGLRenderer(resolve: OffscreenGLContext.resolve, isGLES: OffscreenGLContext.isGLES) { name in
                let source = try PortableGLRenderer.bundledShader(name)
                return springs && name == "frame.vert" ? Self.vertexPrefix + source : source
            }
        }
        guard let renderer else { throw OffscreenRenderError.capture("No spring render pipeline") }
        rune_gl_frame_springs(renderer.handle, tracksTexture, idsTexture, sampleTime.x, sampleTime.y)
        // Retaining the array forces copy-on-write if its caller edits it. Equal
        // addresses then identify the same bytes uploaded on the previous draw.
        // Multi-page atlas preparation can rewrite those bytes.
        let canRetain = tracksTexture != 0 && frame.imagePages.isEmpty
        let reuse = canRetain && retainedInstances?.count == frame.instances.count &&
            frame.instances.withUnsafeBufferPointer { next in
                retainedInstances?.withUnsafeBufferPointer { $0.baseAddress == next.baseAddress } == true
            }
        rune_gl_reuse_spring_instances(renderer.handle, reuse ? 1 : 0)
        retainedInstances = nil
        try renderer.draw(frame)
        if canRetain { retainedInstances = frame.instances }
    }

    package func submitOffscreen(_ frame: RenderFrame) throws -> ContinuousClock.Instant {
        try context.bindFramebuffer(width: frame.width, height: frame.height)
        try paint(frame)
        return try context.finishSubmission(renderer?.handle)
    }

    package func renderOffscreen(_ frame: RenderFrame) throws -> Frame {
        try context.withFramebuffer(width: frame.width, height: frame.height) { try paint(frame) }
    }

    package func close() {
        guard let passes else { return }
        if (try? context.makeCurrent()) != nil {
            renderer?.close()
            rune_gl_pass_delete_texture(passes, idsTexture)
            rune_gl_pass_delete_texture(passes, tracksTexture)
            rune_gl_pass_close(passes)
        } else {
            renderer?.abandon()
            rune_gl_pass_abandon(passes)
        }
        self.passes = nil
        context.close()
    }

    deinit { close() }
}
#endif
