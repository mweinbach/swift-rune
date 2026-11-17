#if canImport(CRuneGL)
import CRuneGL
import Foundation
import Rune
import RuneRef

/// Borrowed textures from a frame rendered with cascade inspection enabled.
/// Light-field coordinates follow the Rune scene, with scene row zero at GL texture row zero.
public struct LightGLInspect {
    public let field, emission, occluders, fluence: UInt32
    public let merged, own: [UInt32]
    public let giSize, fieldSize: (UInt32, UInt32)
    public let texel: Float
}

/// Direct lights, soft shadows and radiance cascades on OpenGL 3.3 / OpenGL ES 3.
/// Construct, render and close with the same context current on its owning thread.
/// The context must support rendering into RGBA16F color attachments.
public final class LightGLRenderer {
    public struct RenderError: Error, CustomStringConvertible {
        public let description: String
        init(_ message: String) { description = message }
    }

    public let adapterName: String
    public private(set) var passCount = 0
    /// Preserve each cascade and render its unmerged interval for inspection.
    public var inspectCascades = false
    private var inspection: LightGLInspect?
    /// Valid after a GI frame rendered with inspection enabled, until the next render or close.
    public func inspect() -> LightGLInspect? { inspection }
    /// Low-resolution incident light, available after a GI frame. Owned by the renderer.
    public private(set) var fluenceTexture: UInt32?
    /// The visibility texture contains one horizontal band for each four lights, followed by any shaft bands.
    /// Texel (x, y) in the first band measures light 0 at Rune pixel (2*x + 1, 2*y + 1).
    public private(set) var visibilityTexture: UInt32?

    private var timing: LightGLTiming?

    /// Enable asynchronous GPU pass timings while this renderer's context is current.
    /// Returns false when the driver exposes no usable timer queries. On GLES this
    /// recorder must be the sole consumer of the context's disjoint timer status.
    @discardableResult
    public func enableTimings(resolve: RuneGLResolve) -> Bool {
        guard device != nil else { return false }
        if timing == nil { timing = LightGLTiming(resolve: resolve) }
        return timing != nil
    }

    /// Stop measuring and release outstanding queries in the current context.
    public func disableTimings() {
        timing?.close(contextIsCurrent: true)
        timing = nil
    }

    /// Consume the oldest completed GPU frame in milliseconds, optionally waiting for it.
    /// Up to three samples queue; the renderer skips timing while that queue is full.
    public func readTimings(wait: Bool = false) -> LightTimings? { timing?.read(wait: wait) }

    private enum Pass: String, CaseIterable {
        case field, gbuffer, shadow, giScene = "gi-scene", cascade, fluence, composite

        func timingLabel(level: UInt32) -> UInt32 {
            switch self {
            case .gbuffer, .composite: LightGLTiming.Stage.raster.rawValue
            case .field: LightGLTiming.Stage.field.rawValue
            case .shadow: LightGLTiming.Stage.shadows.rawValue
            case .giScene: LightGLTiming.Stage.scene.rawValue
            case .cascade: LightGLTiming.Stage.firstCascade.rawValue + level
            case .fluence: LightGLTiming.Stage.fluence.rawValue
            }
        }
    }
    private enum Target: Hashable {
        case field, gbuffer, shadow, emission, occluders, cascadeEven, cascadeOdd, fluence
        case merged(UInt32), own(UInt32)
    }
    private var device: OpaquePointer?
    private var programs: [Pass: OpaquePointer] = [:]
    private var targets: [Target: RuneGLPassTarget] = [:]
    /// Number of resident GI attachments, used by the frame benchmark to check lazy allocation.
    package var allocatedGITextureCount: Int {
        targets.keys.reduce(into: 0) { count, key in
            switch key {
            case .field, .gbuffer, .shadow: break
            default: count += 1
            }
        }
    }

    private var primTexture: UInt32 = 0
    private var cachedPrims: [Prim]?
    private var targetSize = SIMD2<Int32>.zero
    private var geometryReady = false

    #if os(Linux) || os(Windows) || os(macOS)
    private var offscreen: OffscreenGLContext?
    private var captureSize = SIMD2<Int>.zero

    /// Creates a windowless renderer. Texture inputs are allocated in its current GL context.
    public convenience init(width: UInt32, height: UInt32) throws {
        guard (1...16384).contains(width), (1...16384).contains(height) else {
            throw RenderError("Invalid offscreen lighting dimensions")
        }
        let ctx = try OffscreenGLContext()
        try self.init(resolve: OffscreenGLContext.resolve)
        offscreen = ctx
        captureSize = SIMD2(Int(width), Int(height))
    }

    /// Captures the lighting result with top-down, sRGB RGBA8 rows.
    public func renderOffscreen(scene: LightScene, baseTexture: UInt32, textTexture: UInt32 = 0,
                                emissionTexture: UInt32? = nil) throws -> Frame? {
        guard let offscreen else { throw RenderError("A windowless light renderer is required for capture") }
        try offscreen.makeCurrent()
        var active = false
        let frame = try offscreen.withFramebuffer(width: captureSize.x, height: captureSize.y) {
            active = try render(scene: scene, width: captureSize.x, height: captureSize.y,
                                baseTexture: baseTexture, textTexture: textTexture, emissionTexture: emissionTexture)
        }
        return active ? frame : nil
    }
    #endif

    public init(resolve: RuneGLResolve, shaderSource: ((String) throws -> String)? = nil) throws {
        var error = [CChar](repeating: 0, count: 2048)
        let capacity = error.count
        guard let device = rune_gl_pass_open(resolve, &error, capacity) else { throw Self.error(error) }
        self.device = device
        adapterName = String(cString: rune_gl_pass_adapter(device))
        do {
            let load = shaderSource ?? Self.shader
            let vertex = try load("light.vert")
            let common = try load("common.glsl")
            for pass in Pass.allCases {
                let fragment = try common + "\n" + load(pass.rawValue + ".frag")
                let stageVertex = pass == .gbuffer
                    ? try "#define RUNE_LIGHT_VERTEX 1\n" + common + "\n" + load("gbuffer.vert")
                    : vertex
                guard let program = rune_gl_pass_program(device, stageVertex, fragment, &error, capacity) else {
                    throw RenderError("\(pass.rawValue) lighting shader: \(Self.error(error))")
                }
                programs[pass] = program
            }
        } catch {
            close()
            throw error
        }
    }

    static func shader(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "GL") else {
            throw RenderError("Missing RuneLight shader \(name)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func error(_ bytes: [CChar]) -> RenderError {
        RenderError(String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
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
        timing?.close(contextIsCurrent: current != nil)
        timing = nil
        for value in programs.values { rune_gl_pass_delete_program(current, value) }
        programs.removeAll()
        fluenceTexture = nil
        visibilityTexture = nil
        inspection = nil
        if let current {
            clearTargets(current)
            rune_gl_pass_delete_texture(current, primTexture)
            rune_gl_pass_close(current)
        } else {
            targets.removeAll()
            rune_gl_pass_abandon(device)
        }
        primTexture = 0
        cachedPrims = nil
        self.device = nil
        #if os(Linux) || os(Windows) || os(macOS)
        offscreen?.close()
        offscreen = nil
        #endif
    }
    deinit { close() }

    private func clearTargets(_ device: OpaquePointer) {
        for var target in targets.values { rune_gl_pass_delete_target(device, &target) }
        targets.removeAll()
    }

    private func target(_ key: Target, _ w: Int32, _ h: Int32, linear: Bool = true) throws -> RuneGLPassTarget {
        if let old = targets[key], old.width == w, old.height == h { return old }
        var target = RuneGLPassTarget()
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        guard rune_gl_pass_target(device, RuneGLPassRGBA16F, w, h, linear ? 1 : 0,
                                  &target, &error, capacity) != 0 else { throw Self.error(error) }
        if var old = targets.updateValue(target, forKey: key) { rune_gl_pass_delete_target(device, &old) }
        return target
    }

    private func uploadPrimitives(_ prims: [Prim]) throws {
        guard cachedPrims != prims else { return }
        guard let height = Int32(exactly: max(1, prims.count)) else { throw RenderError("Too many lighting primitives") }
        var error = [CChar](repeating: 0, count: 512)
        let capacity = error.count
        let sameSize = primTexture != 0 && cachedPrims?.count == prims.count
        try prims.withUnsafeBytes { raw in
            if sameSize {
                guard rune_gl_pass_update_texture(device, primTexture, RuneGLPassRGBA32F, 6, height,
                                                  raw.baseAddress, &error, capacity) != 0 else { throw Self.error(error) }
            } else {
                let tex = rune_gl_pass_texture(device, RuneGLPassRGBA32F, 6, height,
                                              prims.isEmpty ? nil : raw.baseAddress, 0, &error, capacity)
                guard tex != 0 else { throw Self.error(error) }
                rune_gl_pass_delete_texture(device, primTexture)
                primTexture = tex
            }
        }
        cachedPrims = prims
        geometryReady = false
    }

    private func emission(for scene: LightScene, override: UInt32?) -> UInt32 {
        #if canImport(Metal)
        return override ?? 0
        #else
        return override ?? scene.emission ?? 0
        #endif
    }

    public func hasActiveLighting(_ scene: LightScene, emissionTexture: UInt32? = nil) -> Bool {
        if !scene.lights.isEmpty { return true }
        guard scene.settings.gi != nil else { return false }
        return emission(for: scene, override: emissionTexture) != 0 || scene.prims.contains { $0.flags & flagEmissive != 0 }
    }

    /// Inputs are full-size linear-color GL textures in normal framebuffer orientation. Text is premultiplied.
    /// Supply a zero GL texture for an empty text layer. Inputs must be distinct from the destination.
    /// A lighting-free scene returns false and leaves the destination untouched, matching Metal.
    @discardableResult
    public func render(
        scene: LightScene, width: Int, height: Int, baseTexture: UInt32, textTexture: UInt32,
        framebuffer: UInt32? = nil, emissionTexture: UInt32? = nil, encodeSRGB: Bool = true
    ) throws -> Bool {
        passCount = 0
        fluenceTexture = nil
        visibilityTexture = nil
        inspection = nil
        guard let device else { throw RenderError("RuneLight GL renderer is closed") }
        guard (1...16384).contains(width), (1...16384).contains(height), baseTexture != 0 else {
            throw RenderError("Lighting requires a base texture and dimensions between 1 and 16384")
        }
        guard hasActiveLighting(scene, emissionTexture: emissionTexture) else { return false }
        let emissionInput = emission(for: scene, override: emissionTexture)
        guard MemoryLayout<Prim>.stride == 96 && MemoryLayout<Light>.stride == 64
                && MemoryLayout<LightFrameUniforms>.stride == 144 else { throw RenderError("Invalid RuneLight GPU record layout") }
        let destination = framebuffer ?? rune_gl_pass_current_framebuffer(device)
        try uploadPrimitives(scene.prims)
        let w = Int32(width), h = Int32(height), fw = (w + 1) / 2, fh = (h + 1) / 2
        let gw = ((w + 127) / 128) * 16, gh = ((h + 127) / 128) * 16
        if targetSize != SIMD2(w, h) {
            clearTargets(device)
            targetSize = SIMD2(w, h)
            geometryReady = false
        }

        var frame = LightFrameUniforms.make(
            scene: scene, width: UInt32(w), height: UInt32(h), fieldSize: (UInt32(fw), UInt32(fh)),
            giSize: (UInt32(gw), UInt32(gh)), encode: encodeSRGB, extraEmission: emissionInput != 0)
        let groupCount = max(1, (Int32(frame.counts.y) + 3) / 4)
        let shaftBands: Int32 = frame.counts.w & 2 == 0 ? 1 : 2
        let field = try target(.field, fw, fh)
        let gbuffer = try target(.gbuffer, w, h, linear: false)
        let shadows = try target(.shadow, fw, fh * groupCount * shaftBands, linear: false)

        // std140 layout: Frame (144 bytes), uvec4 stage, eight 64-byte lights.
        var block = [UInt8](repeating: 0, count: 160 + maxLights * 64)
        withUnsafeBytes(of: &frame) { block.replaceSubrange(0..<144, with: $0) }
        scene.lights.prefix(maxLights).withUnsafeBytes { block.replaceSubrange(160..<(160 + $0.count), with: $0) }
        let sample = timing?.begin() == true ? timing : nil
        defer { sample?.cancel() }
        func draw(_ pass: Pass, _ dst: RuneGLPassTarget, _ textures: [UInt32],
                  stage: SIMD4<UInt32> = .zero, instances: Int32 = 1) throws {
            withUnsafeBytes(of: stage) { block.replaceSubrange(144..<160, with: $0) }
            var error = [CChar](repeating: 0, count: 1024)
            let capacity = error.count
            let ok = block.withUnsafeBytes { uniforms in
                rune_gl_pass_draw_instances(device, programs[pass], dst.framebuffer, dst.width, dst.height, textures,
                                            textures.count, uniforms.baseAddress, uniforms.count, RuneGLPassReplace,
                                            instances, &error, capacity)
            }
            guard ok != 0 else { throw RenderError("\(pass.rawValue) lighting pass: \(Self.error(error))") }
            sample?.mark(pass.timingLabel(level: stage.x))
            passCount += 1
        }

        if !geometryReady {
            rune_gl_pass_clear(device, gbuffer, 10000, 0, 0, 0)
            try draw(.gbuffer, gbuffer, [primTexture], instances: Int32(scene.prims.count))
            try draw(.field, field, [primTexture])
            geometryReady = true
        }
        try draw(.shadow, shadows, [0, field.texture, gbuffer.texture])
        var fluence: UInt32 = 0
        if frame.counts.w & 1 != 0 {
            let emission = try target(.emission, gw, gh)
            let occluders = try target(.occluders, gw, gh)
            let sources = [primTexture, shadows.texture, emissionInput]
            try draw(.giScene, emission, sources)
            try draw(.giScene, occluders, sources, stage: SIMD4(0, 1, 0, 0))
            var upper: UInt32 = 0
            var mergedTextures: [UInt32] = [], ownTextures: [UInt32] = []
            for level in (0..<lightCascades).reversed() {
                let mergedKey: Target = inspectCascades ? .merged(level) : (level.isMultiple(of: 2) ? .cascadeEven : .cascadeOdd)
                let merged = try target(mergedKey, gw * 2, gh * 2)
                let inputs = [emission.texture, occluders.texture, field.texture, upper, gbuffer.texture]
                try draw(.cascade, merged, inputs, stage: SIMD4(level, 0, 0, 0))
                upper = merged.texture
                if inspectCascades {
                    let own = try target(.own(level), gw * 2, gh * 2)
                    try draw(.cascade, own, inputs, stage: SIMD4(level, 0, 0, 1))
                    mergedTextures.append(merged.texture)
                    ownTextures.append(own.texture)
                }
            }
            let incident = try target(.fluence, gw, gh)
            try draw(.fluence, incident, [upper])
            fluence = incident.texture
            if inspectCascades {
                inspection = LightGLInspect(field: field.texture, emission: emission.texture,
                                            occluders: occluders.texture, fluence: fluence,
                                            merged: mergedTextures.reversed(), own: ownTextures.reversed(),
                                            giSize: (UInt32(gw), UInt32(gh)), fieldSize: (UInt32(fw), UInt32(fh)),
                                            texel: 1 / giScale)
            }
        }
        let output = RuneGLPassTarget(texture: 0, framebuffer: destination, width: w, height: h)
        try draw(.composite, output, [primTexture, baseTexture, textTexture, gbuffer.texture, shadows.texture, fluence, field.texture],
                 stage: SIMD4(0, 0, textTexture == 0 ? 0 : 1, 0))
        fluenceTexture = fluence != 0 ? fluence : nil
        visibilityTexture = shadows.texture
        sample?.end()
        return true
    }
}
#endif
