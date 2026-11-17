#if canImport(CRuneGL)
import CRuneGL
import Foundation
import Rune
import RuneRef

/// Thick refractive glass, its thirteen-tap backdrop pyramid and spectral dispersion on GL / GLES.
/// All calls, including close, require the creating context to be current on the same thread.
/// The context must support rendering into RGBA16F color attachments.
public final class GlassGLRenderer {
    private var device: OpaquePointer?
    private var glassProgram: OpaquePointer?
    private var pyramidProgram: OpaquePointer?
    private var pyramid: [RuneGLPassTarget] = []
    private var size = SIMD2<Int32>.zero

    #if os(Linux) || os(Windows) || os(macOS)
    private var offscreen: OffscreenGLContext?
    private var captureSize = SIMD2<Int>.zero

    /// Creates a windowless glass renderer with a current GL context for texture inputs.
    public convenience init(width: UInt32 = 1, height: UInt32 = 1) throws {
        guard (1...16384).contains(width), (1...16384).contains(height) else {
            throw LightGLRenderer.RenderError("Invalid offscreen glass dimensions")
        }
        let ctx = try OffscreenGLContext()
        try self.init(resolve: OffscreenGLContext.resolve)
        offscreen = ctx
        captureSize = SIMD2(Int(width), Int(height))
    }

    public func renderOffscreen(glass: [Glass], lights: [GlassLight] = [], settings: GlassSettings = GlassSettings(),
                                backdrop: UInt32, fluence: UInt32? = nil) throws -> Frame {
        guard let offscreen else { throw LightGLRenderer.RenderError("A windowless glass renderer is required for capture") }
        try offscreen.makeCurrent()
        return try offscreen.withFramebuffer(width: captureSize.x, height: captureSize.y) {
            try render(glass: glass, lights: lights, settings: settings, width: captureSize.x, height: captureSize.y,
                       backdrop: backdrop, fluence: fluence)
        }
    }
    #endif

    public init(resolve: RuneGLResolve, shaderSource: ((String) throws -> String)? = nil) throws {
        var error = [CChar](repeating: 0, count: 2048)
        let capacity = error.count
        guard let device = rune_gl_pass_open(resolve, &error, capacity) else { throw LightGLRenderer.error(error) }
        self.device = device
        do {
            let load = shaderSource ?? LightGLRenderer.shader
            let vertex = try load("light.vert")
            func program(_ name: String) throws -> OpaquePointer {
                guard let p = try rune_gl_pass_program(device, vertex, load(name), &error, capacity) else {
                    throw LightGLRenderer.RenderError("\(name): \(LightGLRenderer.error(error))")
                }
                return p
            }
            pyramidProgram = try program("glass-pyramid.frag")
            glassProgram = try program("glass.frag")
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        #if os(Linux) || os(Windows) || os(macOS)
        do { try offscreen?.makeCurrent() } catch { abandon(); return }
        #endif
        release(contextIsCurrent: true)
    }

    /// Releases CPU ownership after the GL context was lost or destroyed.
    public func abandon() {
        release(contextIsCurrent: false)
    }

    private func release(contextIsCurrent: Bool) {
        guard let device else { return }
        let current = contextIsCurrent ? device : nil
        for var level in pyramid { rune_gl_pass_delete_target(current, &level) }
        pyramid.removeAll()
        rune_gl_pass_delete_program(current, glassProgram)
        rune_gl_pass_delete_program(current, pyramidProgram)
        if let current { rune_gl_pass_close(current) } else { rune_gl_pass_abandon(device) }
        self.device = nil
        #if os(Linux) || os(Windows) || os(macOS)
        offscreen?.close()
        offscreen = nil
        #endif
    }
    deinit { close() }

    private func ensurePyramid(width: Int32, height: Int32) throws {
        let dimensions = SIMD2(width, height)
        guard size != dimensions else { return }
        var w = (width + 1) / 2, h = (height + 1) / 2
        var levels: [RuneGLPassTarget] = []
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        for _ in 0..<glassPyramidLevels {
            var target = RuneGLPassTarget()
            guard rune_gl_pass_target(device, RuneGLPassRGBA16F, w, h, 1, &target, &error, capacity) != 0 else {
                for var made in levels { rune_gl_pass_delete_target(device, &made) }
                throw LightGLRenderer.error(error)
            }
            levels.append(target)
            if w == 1 && h == 1 { break }
            w = max(w / 2, 1)
            h = max(h / 2, 1)
        }
        for var old in pyramid { rune_gl_pass_delete_target(device, &old) }
        pyramid = levels
        size = dimensions
    }

    /// Backdrop and output are full-size GL framebuffer textures. The optional fluence is
    /// LightGLRenderer.fluenceTexture. The destination must not alias a sampled texture.
    public func render(
        glass: [Glass], lights: [GlassLight] = [], settings: GlassSettings = GlassSettings(),
        width: Int, height: Int, backdrop: UInt32, fluence: UInt32? = nil, framebuffer: UInt32? = nil
    ) throws {
        guard let device else { throw LightGLRenderer.RenderError("Rune glass GL renderer is closed") }
        guard (1...16384).contains(width), (1...16384).contains(height), backdrop != 0 else {
            throw LightGLRenderer.RenderError("Glass requires a backdrop and dimensions between 1 and 16384")
        }
        guard MemoryLayout<GlassUniforms>.stride == 48, MemoryLayout<Glass>.stride == 96,
              MemoryLayout<GlassLight>.stride == 32 else { throw LightGLRenderer.RenderError("Invalid Rune glass GPU record layout") }
        let destination = framebuffer ?? rune_gl_pass_current_framebuffer(device)
        let ng = min(maxGlass, glass.count), nl = min(maxGlassLights, lights.count)
        var error = [CChar](repeating: 0, count: 1024)
        let capacity = error.count
        var textures = [backdrop, fluence ?? 0]
        if ng > 0 {
            try ensurePyramid(width: Int32(width), height: Int32(height))
            var src = backdrop
            for level in pyramid {
                let dimensions = SIMD4(Float(level.width), Float(level.height), 0, 0)
                let ok = withUnsafeBytes(of: dimensions) { raw in
                    rune_gl_pass_draw(device, pyramidProgram, level.framebuffer, level.width, level.height,
                                      [src], 1, raw.baseAddress, raw.count, RuneGLPassReplace, &error, capacity)
                }
                if ok == 0 { throw LightGLRenderer.error(error) }
                textures.append(level.texture)
                src = level.texture
            }
        }
        var uniform = GlassUniforms()
        uniform.size = SIMD4(Float(width), Float(height), Float(ng), Float(nl))
        uniform.misc = SIMD4(Float(pyramid.count), settings.env, settings.shadow, settings.caustic)
        uniform.shadow = SIMD4(settings.shadowOffset.x, settings.shadowOffset.y, settings.shadowBlur, 0)
        let lightOffset = 48 + maxGlass * 96
        var block = [UInt8](repeating: 0, count: lightOffset + maxGlassLights * 32)
        withUnsafeBytes(of: uniform) { block.replaceSubrange(0..<48, with: $0) }
        glass.prefix(ng).withUnsafeBytes { block.replaceSubrange(48..<(48 + $0.count), with: $0) }
        lights.prefix(nl).withUnsafeBytes { block.replaceSubrange(lightOffset..<(lightOffset + $0.count), with: $0) }
        let ok = rune_gl_pass_draw(device, glassProgram, destination, Int32(width), Int32(height), textures,
                                   textures.count, block, block.count, RuneGLPassReplace, &error, capacity)
        if ok == 0 { throw LightGLRenderer.error(error) }
    }
}
#endif
