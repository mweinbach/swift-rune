#if os(Linux) || os(Windows)
import CRuneGL
import Foundation
import Rune

/// Evaluates the same shader used to animate Rune's primitives and reads its results back for comparison.
func sampleGLSpringTracks(
    _ tracks: [(track: GPUSpringTrack, now: Double, expectedPos: Float, expectedVel: Float, opacity: Bool)]
) throws -> [SIMD4<Float>] {
    guard !tracks.isEmpty else { return [] }
    let context = try OffscreenGLContext()
    defer { context.close() }
    var message = [CChar](repeating: 0, count: 2048)
    let capacity = message.count
    func failure() -> NSError {
        let reason = String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return NSError(domain: "RuneGpuSprings", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
    guard let device = rune_gl_pass_open(OffscreenGLContext.resolve, &message, capacity) else { throw failure() }
    defer { rune_gl_pass_close(device) }
    guard let disableAddress = OffscreenGLContext.resolve("glDisable") else {
        throw NSError(domain: "RuneGpuSprings", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing glDisable"])
    }
    let disable = unsafeBitCast(disableAddress, to: (@convention(c) (UInt32) -> Void).self)
    disable(0x0BD0) // GL_DITHER can alter the encoded mantissa bytes in a normalized color attachment.

    // Each vertex instance covers three pixels. Their RGBA8 channels carry the exact IEEE bits of
    // position, velocity and clamped opacity, even on ES 3 devices without float render targets.
    let vertex = GLSpringFrameRenderer.sampleGLSL + """

    uniform sampler2D uTex0;
    flat out vec3 result;
    void main() {
        ivec2 size = textureSize(uTex0, 0);
        int columns = size.x / 4;
        ivec2 cell = ivec2(gl_InstanceID % columns, gl_InstanceID / columns);
        ivec2 p = ivec2(cell.x * 4, cell.y);
        vec2 state = runeSpringSample(texelFetch(uTex0, p, 0),
                                     texelFetchOffset(uTex0, p, 0, ivec2(1, 0)),
                                     texelFetchOffset(uTex0, p, 0, ivec2(2, 0)),
                                     texelFetchOffset(uTex0, p, 0, ivec2(3, 0)).xy);
        result = vec3(state, clamp(state.x, 0.0, 1.0));
        ivec2 corner = ivec2(gl_VertexID & 1, gl_VertexID >> 1);
        gl_Position = vec4(2.0 * vec2(cell + corner) / vec2(columns, size.y) - 1.0, 0.0, 1.0);
    }
    """
    let fragment = """
    flat in vec3 result;
    out vec4 color;
    void main() {
        uint bits = floatBitsToUint(result[int(gl_FragCoord.x) % 3]);
        uvec4 bytes = (uvec4(bits) >> uvec4(0, 8, 16, 24)) & uvec4(255);
        color = vec4(bytes) / 255.0;
    }
    """
    guard let program = rune_gl_pass_program(device, vertex, fragment, &message, capacity) else { throw failure() }
    defer { rune_gl_pass_delete_program(device, program) }

    var samples: [SIMD4<Float>] = []
    samples.reserveCapacity(tracks.count)
    let columns = min(256, tracks.count)
    // Both textures stay within the minimum texture size supported by the desktop and ES profiles.
    for first in stride(from: 0, to: tracks.count, by: columns * 1024) {
        let count = min(tracks.count - first, columns * 1024)
        let rows = (count + columns - 1) / columns
        var input = [SIMD4<Float>](repeating: .zero, count: columns * rows * 4)
        for i in 0..<count {
            let query = tracks[first + i]
            let track = query.track
            let time = splitSpringTime(query.now)
            input[4 * i] = track.abcd
            input[4 * i + 1] = SIMD4(track.rates.x, track.rates.y, track.goal, Float(track.kind))
            input[4 * i + 2] = SIMD4(track.start.x, track.start.y, track.duration, 0)
            input[4 * i + 3] = SIMD4(time.x, time.y, 0, 0)
        }
        var texture = input.withUnsafeBytes {
            rune_gl_pass_texture(device, RuneGLPassRGBA32F, Int32(columns * 4), Int32(rows),
                                 $0.baseAddress, 0, &message, capacity)
        }
        guard texture != 0 else { throw failure() }
        defer { rune_gl_pass_delete_texture(device, texture) }
        var target = RuneGLPassTarget()
        guard rune_gl_pass_target(device, RuneGLPassRGBA8, Int32(columns * 3), Int32(rows),
                                  0, &target, &message, capacity) != 0 else { throw failure() }
        defer { rune_gl_pass_delete_target(device, &target) }
        guard rune_gl_pass_draw_instances(device, program, target.framebuffer, target.width, target.height,
                                          &texture, 1, nil, 0, RuneGLPassReplace, Int32(count),
                                          &message, capacity) != 0 else { throw failure() }

        var pixels = [UInt8](repeating: 0, count: columns * rows * 12)
        let byteCount = pixels.count
        guard rune_gl_pass_read(device, target, &pixels, byteCount, &message, capacity) != 0 else { throw failure() }
        func value(at offset: Int) -> Float {
            let lo = UInt32(pixels[offset]) | UInt32(pixels[offset + 1]) << 8
            let hi = UInt32(pixels[offset + 2]) << 16 | UInt32(pixels[offset + 3]) << 24
            return Float(bitPattern: lo | hi)
        }
        for offset in stride(from: 0, to: count * 12, by: 12) {
            samples.append(SIMD4(value(at: offset), value(at: offset + 4), value(at: offset + 8), 1))
        }
    }
    return samples
}
#endif
