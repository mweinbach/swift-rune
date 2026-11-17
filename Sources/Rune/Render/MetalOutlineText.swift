#if canImport(Metal) && canImport(QuartzCore)
import Foundation
@preconcurrency import Metal

/// Windfoil is installed only for a draw that requested vector or LCD glyphs.
internal final class MetalOutlineText {
    private struct PipelineKey: Hashable {
        let format: MTLPixelFormat
        let additive: Bool
        let dualSource: Bool
        let replacing: Bool
    }

    private let device: MTLDevice
    private var fragments: [Bool: MTLFunction] = [:]
    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    private var refused: Set<PipelineKey> = []
    private var texture: MTLTexture?
    private var storeID: UUID?
    private var generation: UInt64 = 0
    private var usedTexels = 0

    private struct Reader {
        weak var command: MTLCommandBuffer?

        var pending: Bool {
            guard let command else { return false }
            return command.status != .completed && command.status != .error
        }
    }

    private var readers: [Reader] = []
    private(set) var uploadBytes: UInt64 = 0
    private(set) var vectorDrawBatches: UInt64 = 0
    private(set) var lcdDrawBatches: UInt64 = 0

    init(device: MTLDevice) { self.device = device }

    func pipeline(vertex: MTLFunction, format: MTLPixelFormat, additive: Bool,
                  dualSource: Bool, replacing: Bool = false) -> MTLRenderPipelineState? {
        let key = PipelineKey(format: format, additive: additive, dualSource: dualSource, replacing: replacing)
        if let cached = pipelines[key] { return cached }
        if refused.contains(key) { return nil }
        do {
            let fragment: MTLFunction
            if let cached = fragments[dualSource] {
                fragment = cached
            } else {
                let library = try ShaderLibraryCache.load(
                    named: dualSource ? "shader_windfoil_rgb" : "shader_windfoil",
                    source: RenderShaders.windfoilMSL(dualSource: dualSource),
                    requiredFunction: "fs_windfoil", on: device)
                let values = MTLFunctionConstantValues()
                var subpixel = dualSource
                values.setConstantValue(&subpixel, type: .bool, index: 0)
                fragment = try library.makeFunction(name: "fs_windfoil", constantValues: values)
                fragments[dualSource] = fragment
            }
            let state = try RenderFrameEngine.makePipeline(device: device, vert: vertex, frag: fragment,
                                                           format: format, additive: additive, dualSource: dualSource, replacing: replacing)
            pipelines[key] = state
            return state
        } catch {
            refused.insert(key)
            let mode = dualSource ? "subpixel blending" : "vector glyphs"
            RuneStandardIO.error("Rune Metal: \(mode) unavailable for \(format) (\(error)).\n")
            return nil
        }
    }

    func sync(_ atlas: RenderOutlineAtlas, readBy command: MTLCommandBuffer) throws -> MTLTexture {
        let width = Int(OutlineStore.width)
        let rows = (atlas.usedTexels + width - 1) / width
        guard rows > 0 && rows <= Int(OutlineStore.maxRows) && atlas.texels.count >= rows * width else {
            throw MetalRenderer.RendererError.textureAllocationFailed(resource: "Glyph outlines", width: width, height: rows)
        }
        readers.removeAll { !$0.pending }
        let sameGeneration = storeID == atlas.storeID && generation == atlas.generation
        // Appending a record can modify the last row an earlier command still samples.
        // Keep its entire texture immutable until the GPU is finished.
        let changes = !sameGeneration || usedTexels < atlas.usedTexels
        let replace = texture == nil || texture!.height < rows || (changes && !readers.isEmpty)
        if replace {
            var capacity = 1
            while capacity < rows { capacity *= 2 }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Uint, width: width,
                                                                height: capacity, mipmapped: false)
            desc.usage = .shaderRead
            #if os(macOS)
            desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
            #else
            desc.storageMode = .shared
            #endif
            guard let next = device.makeTexture(descriptor: desc) else {
                throw MetalRenderer.RendererError.textureAllocationFailed(resource: "Glyph outlines", width: width, height: capacity)
            }
            next.label = "Rune glyph outlines"
            texture = next
            readers.removeAll(keepingCapacity: true)
        }
        let current = texture!
        if replace || changes {
            let start = replace || !sameGeneration ? 0 : usedTexels / width
            let bytesPerRow = width * MemoryLayout<SIMD4<UInt32>>.stride
            atlas.texels.withUnsafeBytes { bytes in
                current.replace(region: MTLRegionMake2D(0, start, width, rows - start), mipmapLevel: 0,
                                withBytes: bytes.baseAddress!.advanced(by: start * bytesPerRow), bytesPerRow: bytesPerRow)
            }
            uploadBytes &+= UInt64((rows - start) * bytesPerRow)
            storeID = atlas.storeID
            generation = atlas.generation
            usedTexels = atlas.usedTexels
        }
        if !readers.contains(where: { $0.command === command }) { readers.append(Reader(command: command)) }
        return current
    }

    func recordDraw(dualSource: Bool) {
        vectorDrawBatches &+= 1
        if dualSource { lcdDrawBatches &+= 1 }
    }

    func giveBack() {
        texture = nil
        storeID = nil
        readers.removeAll()
        usedTexels = 0
    }
}
#endif
