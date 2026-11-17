#if canImport(CRuneGL)
import CRuneGL
import Foundation
import Rune

/// The GL renderer accepts the same packed effect graph, layer order, and texture slots as Metal.
/// Its methods and destruction require the creating GL context to be current on the calling thread.
public final class FxGLRenderer {
    public struct RenderError: Error, CustomStringConvertible {
        public let description: String
        init(_ message: String) { description = message }
    }

    private struct Uniforms {
        var instance: FxInstRaw
        var globals: SIMD4<Float>
        var backdrop: SIMD4<Float>
    }

    private(set) var device: OpaquePointer?
    let shader: (String) throws -> String
    private let vertex: String
    private let common: String
    private let quad: String
    private var programs: [String: OpaquePointer] = [:]
    private var tableTexture: UInt32 = 0
    private var tableSize = SIMD2<Int32>.zero
    private var tableData: [SIMD4<Float>]?
    private struct Mask {
        var size: SIMD2<UInt32>
        var levels: [RuneGLPassTarget]
    }
    private var masks: [UInt32: Mask] = [:]
    private var down: [RuneGLPassTarget] = []
    private var up: [RuneGLPassTarget] = []
    private var pyramidViewport = SIMD2<UInt32>.zero

    private var fireSimulation: FxGLFireSimulation?
    private var scratchGraph = FxRenderPassGraph()

    public let adapter: String
    public var options: FxOptions

    /// Supply a host's current GL proc resolver. An optional shader loader can read APK assets.
    public init(resolve: RuneGLResolve, options: FxOptions = FxOptions(),
                shaderSource: ((String) throws -> String)? = nil) throws {
        let load = shaderSource ?? Self.bundled
        shader = load
        let layout = try load("layout.glsl")
        vertex = layout + "\n" + (try load("effect.vert"))
        common = layout + "\n" + (try load("common.glsl"))
        quad = try load("quad.vert")
        self.options = options
        guard MemoryLayout<Uniforms>.stride == 288,
              MemoryLayout<Uniforms>.offset(of: \.globals) == 256,
              MemoryLayout<Uniforms>.offset(of: \.backdrop) == 272 else {
            throw RenderError("RuneFX GL uniform layout does not match std140")
        }
        let handle: OpaquePointer = try Self.checkedPointer { rune_gl_pass_open(resolve, $0, $1) }
        device = handle
        adapter = String(cString: rune_gl_pass_adapter(handle))
    }

    private static func bundled(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "GL") else {
            throw RenderError("RuneFX GL shader missing: \(name)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func checked<T>(_ work: (UnsafeMutablePointer<CChar>, Int) -> T,
                                   success: (T) -> Bool) throws -> T {
        var text = [CChar](repeating: 0, count: 2048)
        let result = text.withUnsafeMutableBufferPointer { work($0.baseAddress!, $0.count) }
        guard success(result) else {
            throw RenderError(String(decoding: text.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self))
        }
        return result
    }

    static func checkedPointer(_ work: (UnsafeMutablePointer<CChar>, Int) -> OpaquePointer?) throws -> OpaquePointer {
        try checked(work, success: { $0 != nil })!
    }

    private static func checkedName(_ work: (UnsafeMutablePointer<CChar>, Int) -> UInt32) throws -> UInt32 {
        try checked(work, success: { $0 != 0 })
    }

    private static func checkedCall(_ work: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        _ = try checked(work, success: { $0 != 0 })
    }

    private func program(_ name: String, effect: Bool = false) throws -> OpaquePointer {
        if let cached = programs[name] { return cached }
        let body = try shader(name + ".frag")
        let compiled = try Self.checkedPointer { error, count in
            rune_gl_pass_program(device, effect ? vertex : quad,
                                 effect ? common + "\n" + body : body, error, count)
        }
        programs[name] = compiled
        return compiled
    }

    public func warmAll() throws {
        guard device != nil else { throw RenderError("RuneFX GL renderer is closed") }
        for kind in FxEffectKind.allCases {
            _ = try program(kind.shaderName, effect: true)
        }
        for name in ["blur-down", "blur-up", "resolve"] {
            _ = try program(name)
        }
    }

    private func uploadTable(_ data: [SIMD4<Float>]) throws {
        guard !data.isEmpty, tableData != data else { return }
        // The GLES 3 minimum maximum texture dimension is 2048. Rows are indexed in the shader.
        let width = min(2048, data.count)
        let height = (data.count - 1) / width + 1
        guard let h = Int32(exactly: height) else { throw RenderError("RuneFX table is too large") }
        let size = SIMD2(Int32(width), h)
        var padded = data
        padded.append(contentsOf: repeatElement(.zero, count: width * height - data.count))
        try padded.withUnsafeBytes { bytes in
            if size == tableSize {
                try Self.checkedCall {
                    rune_gl_pass_update_texture(device, tableTexture, RuneGLPassRGBA32F,
                                                size.x, h, bytes.baseAddress, $0, $1)
                }
            } else {
                let texture = try Self.checkedName {
                    rune_gl_pass_texture(device, RuneGLPassRGBA32F, size.x, h, bytes.baseAddress, 0, $0, $1)
                }
                rune_gl_pass_delete_texture(device, tableTexture)
                tableTexture = texture
                tableSize = size
            }
        }
        tableData = data
    }

    func target(_ size: SIMD2<UInt32>, format: RuneGLPassFormat, linear: Bool = true) throws -> RuneGLPassTarget {
        var target = RuneGLPassTarget()
        try Self.checkedCall {
            rune_gl_pass_target(device, format, Int32(size.x), Int32(size.y), linear ? 1 : 0, &target, $0, $1)
        }
        return target
    }

    func draw<T>(_ program: OpaquePointer, framebuffer: UInt32, viewport: SIMD2<UInt32>,
                 textures: [UInt32], uniforms: T, blend: RuneGLPassBlend) throws {
        try withUnsafeBytes(of: uniforms) { buffer in
            try Self.checkedCall {
                rune_gl_pass_draw(device, program, framebuffer, Int32(viewport.x), Int32(viewport.y),
                                  textures, textures.count, buffer.baseAddress, buffer.count, blend, $0, $1)
            }
        }
    }

    private func discardPyramid() {
        for i in down.indices { rune_gl_pass_delete_target(device, &down[i]) }
        for i in up.indices { rune_gl_pass_delete_target(device, &up[i]) }
        down.removeAll()
        up.removeAll()
        pyramidViewport = .zero
    }

    /// Rebuilds the Kawase blur at the requested radius. Textures are reused across frames.
    private func blur(_ texture: UInt32, viewport: SIMD2<UInt32>, sigma: Float) throws -> UInt32 {
        let base = SIMD2(max((viewport.x + 1) / 2, 1), max((viewport.y + 1) / 2, 1))
        let levels = min(6, 32 - max(base.x, base.y).leadingZeroBitCount)
        guard levels >= 2 else { return texture }
        if pyramidViewport != viewport { discardPyramid() }
        let level = min(max(log2f(max(sigma / 2, 1)), 0), Float(levels - 1))
        let last = max(Int(ceilf(level)), 1)
        let fraction = max(0, min(1, level - Float(last - 1)))
        do {
            while down.count <= last {
                let shift = down.count
                let size = SIMD2(max(base.x >> shift, 1), max(base.y >> shift, 1))
                down.append(try target(size, format: RuneGLPassRGBA16F))
            }
            while up.count < last {
                let size = SIMD2(UInt32(down[up.count].width), UInt32(down[up.count].height))
                up.append(try target(size, format: RuneGLPassRGBA16F))
            }
        } catch {
            discardPyramid()
            throw error
        }
        pyramidViewport = viewport
        var src = texture
        for index in 0...last {
            let dst = down[index]
            try draw(program("blur-down"), framebuffer: dst.framebuffer,
                     viewport: SIMD2(UInt32(dst.width), UInt32(dst.height)),
                     textures: [src], uniforms: SIMD4<Float>.zero, blend: RuneGLPassReplace)
            src = dst.texture
        }
        for index in (0..<last).reversed() {
            let dst = up[index]
            try draw(program("blur-up"), framebuffer: dst.framebuffer,
                     viewport: SIMD2(UInt32(dst.width), UInt32(dst.height)),
                     textures: [src, down[index].texture],
                     uniforms: SIMD4<Float>(index == last - 1 ? fraction : 1, 0, 0, 0), blend: RuneGLPassReplace)
            src = dst.texture
        }
        return src
    }

    /// Allocates a reusable RGBA16F mask texture for source-slot effects such as mask glow.
    /// The returned GL name is valid until removal or renderer shutdown.
    public func makeMaskPyramid(size: SIMD2<UInt32>) throws -> UInt32 {
        try validate(size)
        let mipCount = min(7, 32 - max(size.x, size.y).leadingZeroBitCount)
        let texture = try Self.checkedName {
            rune_gl_pass_mip_texture(device, RuneGLPassRGBA16F, Int32(size.x), Int32(size.y), Int32(mipCount), $0, $1)
        }
        var levels: [RuneGLPassTarget] = []
        do {
            for level in 1..<mipCount {
                let dimensions = SIMD2(max(size.x >> level, 1), max(size.y >> level, 1))
                levels.append(try target(dimensions, format: RuneGLPassRGBA16F))
            }
        } catch {
            for index in levels.indices { rune_gl_pass_delete_target(device, &levels[index]) }
            rune_gl_pass_delete_texture(device, texture)
            throw error
        }
        masks[texture] = Mask(size: size, levels: levels)
        return texture
    }

    /// Rebuilds the mask from a framebuffer of the same size, applying the 13-tap filter per level.
    public func buildMaskMips(_ texture: UInt32, from framebuffer: UInt32) throws {
        guard let mask = masks[texture] else { throw RenderError("Unknown RuneFX mask pyramid") }
        let base = RuneGLPassTarget(texture: 0, framebuffer: framebuffer, width: Int32(mask.size.x), height: Int32(mask.size.y))
        try Self.checkedCall { rune_gl_pass_copy_mip(device, base, texture, 0, $0, $1) }
        var input = texture
        for (index, level) in mask.levels.enumerated() {
            try draw(program("blur-down"), framebuffer: level.framebuffer,
                     viewport: SIMD2(UInt32(level.width), UInt32(level.height)),
                     textures: [input], uniforms: SIMD4<Float>.zero, blend: RuneGLPassReplace)
            try Self.checkedCall { rune_gl_pass_copy_mip(device, level, texture, Int32(index + 1), $0, $1) }
            input = level.texture
        }
    }

    public func removeMaskPyramid(_ texture: UInt32) {
        guard var mask = masks.removeValue(forKey: texture) else { return }
        for index in mask.levels.indices { rune_gl_pass_delete_target(device, &mask.levels[index]) }
        rune_gl_pass_delete_texture(device, texture)
    }

    /// Enables the persistent GPU fluid simulation for top flames and heat.
    /// The default procedural fire pass requires no simulation state.
    public func setFireSim(_ enabled: Bool) {
        if enabled {
            if fireSimulation == nil { fireSimulation = FxGLFireSimulation() }
        } else {
            fireSimulation?.close(using: self)
            fireSimulation = nil
        }
    }

    public func prepare(viewport: SIMD2<UInt32>, layers: [FxLayer], scale: Float = 1,
                        slots: [FxSlot]? = nil, hasBackdrop: Bool = false) -> FxRenderPassGraph {
        scratchGraph.rebuild(viewport: viewport, scale: scale, layers: layers, slots: slots,
                             srgbBlend: options.srgbBlend, hasBackdrop: hasBackdrop,
                             fireSim: fireSimulation?.planner)
        return scratchGraph
    }

    /// Draws in graph order into a caller-owned framebuffer. Pass an original layer index
    /// to interleave individual effects with Rune UI draws. The backdrop is a separate,
    /// immutable texture. Source textures use GL's bottom-up row order and may include
    /// mipmapped alpha masks for mask glow.
    public func encode(graph: FxRenderPassGraph, viewport: SIMD2<UInt32>, framebuffer: UInt32,
                       backdrop: UInt32? = nil, sources: [UInt32] = [], place: Place? = nil,
                       layer: Int? = nil) throws {
        try validate(viewport)
        if let simulationID = graph.simulationID {
            guard let fireSimulation, fireSimulation.planner.identity == simulationID,
                  graph.simulationFrame == fireSimulation.planner.frame else {
                throw RenderError("The fire simulation graph belongs to another renderer or frame")
            }
            try fireSimulation.step(using: self)
        }
        let items = graph.prepared.filter {
            (place == nil || $0.place == place) && (layer == nil || $0.layerIndex == layer)
        }
        guard !items.isEmpty else { return }
        try uploadTable(graph.tableData)
        for item in items {
            var source = item.sourceSlot.flatMap { Int($0) < sources.count ? sources[Int($0)] : nil }
            if let grid = item.fireSimGrid {
                guard let field = fireSimulation?.texture(at: grid) else {
                    throw RenderError("The fire simulation graph must be prepared by this renderer")
                }
                source = field
            }
            var instance = graph.instances[Int(item.instanceIndex)]
            var blurred: UInt32 = 0
            let hasBackdrop = item.needsBackdrop && backdrop != nil
            if let backdrop, item.blurPx > 0 {
                blurred = try blur(backdrop, viewport: viewport, sigma: item.blurPx)
                instance.xf = SIMD4(1, min(item.blurPx / 3, 1), 0, 0)
            }
            let packed = Uniforms(
                instance: instance,
                globals: SIMD4(Float(viewport.x), Float(viewport.y), options.dither ? 1 : 0, options.srgbBlend ? 1 : 0),
                backdrop: SIMD4(item.backdropSrgb ? 1 : 0, hasBackdrop ? 1 : 0, 0, 0)
            )
            try draw(program(item.kind.shaderName, effect: true), framebuffer: framebuffer, viewport: viewport,
                     textures: [item.needsBackdrop ? (backdrop ?? 0) : 0, source ?? 0, blurred,
                                graph.tableData.isEmpty ? 0 : tableTexture],
                     uniforms: packed, blend: item.blend == .screen ? RuneGLPassScreen : RuneGLPassPremultipliedOver)
        }
    }

    private func validate(_ size: SIMD2<UInt32>) throws {
        guard device != nil else { throw RenderError("RuneFX GL renderer is closed") }
        guard size.x > 0, size.y > 0, size.x <= Int32.max, size.y <= Int32.max else {
            throw RenderError("Invalid RuneFX GL viewport \(size.x)x\(size.y)")
        }
    }

    /// Renders an independent effect stack and reads its sRGB8 pixels top-to-bottom.
    public func renderOffscreen(viewport: SIMD2<UInt32>, layers: [FxLayer], scale: Float = 1,
                                slots: [FxSlot]? = nil, clearColor: SIMD4<Float> = .zero,
                                backdrop: UInt32? = nil, sources: [UInt32] = []) throws -> Frame {
        try validate(viewport)
        let graph = prepare(viewport: viewport, layers: layers, scale: scale, slots: slots, hasBackdrop: backdrop != nil)
        var color = try target(viewport, format: RuneGLPassRGBA16F)
        defer { rune_gl_pass_delete_target(device, &color) }
        rune_gl_pass_clear(device, color, clearColor.x, clearColor.y, clearColor.z, clearColor.w)
        try encode(graph: graph, viewport: viewport, framebuffer: color.framebuffer,
                   backdrop: backdrop, sources: sources)
        var resolved = try target(viewport, format: RuneGLPassRGBA8)
        defer { rune_gl_pass_delete_target(device, &resolved) }
        try draw(program("resolve"), framebuffer: resolved.framebuffer, viewport: viewport,
                 textures: [color.texture], uniforms: SIMD4<Float>(options.srgbBlend ? 0 : 1, 0, 0, 0),
                 blend: RuneGLPassReplace)
        let width = Int(viewport.x), height = Int(viewport.y)
        let stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        try bytes.withUnsafeMutableBufferPointer { buffer in
            try Self.checkedCall { rune_gl_pass_read(device, resolved, buffer.baseAddress, buffer.count, $0, $1) }
            // GL readback starts with the bottom row. Swap rows in the existing readback buffer.
            guard height > 1, let base = buffer.baseAddress else { return }
            var scratch = [UInt8](repeating: 0, count: stride)
            scratch.withUnsafeMutableBufferPointer { row in
                for y in 0..<(height / 2) {
                    let top = base.advanced(by: y * stride)
                    let bottom = base.advanced(by: (height - y - 1) * stride)
                    row.baseAddress!.update(from: top, count: stride)
                    top.update(from: bottom, count: stride)
                    bottom.update(from: row.baseAddress!, count: stride)
                }
            }
        }
        return Frame(width: width, height: height, rgba: bytes)
    }

    /// Call while the creating GL context is current and before destroying that context.
    public func close() {
        guard let device else { return }
        setFireSim(false)
        scratchGraph = FxRenderPassGraph()
        tableData = nil
        discardPyramid()
        for program in programs.values { rune_gl_pass_delete_program(device, program) }
        programs.removeAll()
        rune_gl_pass_delete_texture(device, tableTexture)
        for texture in Array(masks.keys) { removeMaskPyramid(texture) }
        rune_gl_pass_close(device)
        self.device = nil
    }

    deinit { close() }
}
#endif
