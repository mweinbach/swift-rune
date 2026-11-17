import Foundation
import RuneRef

/// Binary scene shared with rune-webgl.mjs. WASI runs little-endian; the header is 14 32-bit words.
struct WebScenePacket {
    static let magic: UInt32 = 0x32475352 // RSG2
    static let headerSize = 56
    let scene: RenderFrame
    let glyphUpdate: WebAtlasUpdate
    let imageUpdate: WebAtlasUpdate
    let sequence: SIMD2<UInt32>?
    let byteCount: Int
    let surfaces: WebSurfacePacket

    init?(scene: RenderFrame, sendGlyphs: Bool, sendImages: Bool,
          surfaceCache: WebSurfacePacket.Cache = .init()) throws {
        try self.init(scene: scene, glyphUpdate: sendGlyphs ? .full : .none,
                      imageUpdate: sendImages ? .full : .none, sequence: nil, surfaceCache: surfaceCache)
    }

    init?(scene: RenderFrame, glyphUpdate: WebAtlasUpdate, imageUpdate: WebAtlasUpdate,
          sequence: SIMD2<UInt32>?, surfaceCache: WebSurfacePacket.Cache = .init()) throws {
        guard MemoryLayout<RenderInstance>.stride == 128,
              scene.width > 0, scene.height > 0,
              UInt32(exactly: scene.width) != nil, UInt32(exactly: scene.height) != nil,
              UInt32(exactly: scene.instances.count) != nil else { return nil }
        let (bytes, overflow) = scene.instances.count.multipliedReportingOverflow(by: 128)
        guard !overflow else { return nil }
        let surfaces = try WebSurfacePacket(scene.surfaces, srgbBlend: scene.srgbBlend,
                                            size: SIMD2(UInt32(scene.width), UInt32(scene.height)), previous: surfaceCache)
        guard UInt32(exactly: surfaces.count) != nil else { return nil }
        self.surfaces = surfaces
        func length(_ update: WebAtlasUpdate, texelBytes: Int, channels: Int) -> Int {
            switch update {
            case .none: return 0
            case .full: return texelBytes
            case .patch(let edges): return 16 + (edges.z - edges.x) * (edges.w - edges.y) * channels
            }
        }
        var size = Self.headerSize + (sequence == nil ? 0 : 8)
        for fieldSize in [bytes, length(glyphUpdate, texelBytes: scene.glyphs.texels.count, channels: 1),
                          length(imageUpdate, texelBytes: scene.images.texels.count, channels: 4), surfaces.bytes.count] {
            let (sum, tooLarge) = size.addingReportingOverflow(fieldSize)
            guard !tooLarge else { return nil }
            size = sum
        }
        self.scene = scene
        self.glyphUpdate = glyphUpdate
        self.imageUpdate = imageUpdate
        self.sequence = sequence
        byteCount = size
    }

    func write(to destination: UnsafeMutableRawPointer) {
        func flags(for update: WebAtlasUpdate, full: UInt32, patch: UInt32) -> UInt32 {
            switch update {
            case .none: return 0
            case .full: return full
            case .patch: return patch
            }
        }
        let flags: UInt32 = (scene.srgbBlend ? 1 : 0) | flags(for: glyphUpdate, full: 2, patch: 8)
            | flags(for: imageUpdate, full: 4, patch: 16) | (sequence == nil ? 0 : 32)
        let header: [UInt32] = [
            Self.magic, UInt32(scene.width), UInt32(scene.height), flags, UInt32(scene.instances.count),
            UInt32(scene.glyphs.width), UInt32(scene.glyphs.height), UInt32(scene.images.width), UInt32(scene.images.height),
            scene.clearColor.x.bitPattern, scene.clearColor.y.bitPattern, scene.clearColor.z.bitPattern, scene.clearColor.w.bitPattern, UInt32(surfaces.count),
        ]
        var offset = 0
        func append(_ bytes: UnsafeRawBufferPointer) {
            guard let source = bytes.baseAddress else { return }
            destination.advanced(by: offset).copyMemory(from: source, byteCount: bytes.count)
            offset += bytes.count
        }
        header.withUnsafeBytes(append)
        scene.instances.withUnsafeBytes(append)
        // Explicit marks override the instance's packed mark in the native effect registry.
        for (index, mark) in scene.marks.prefix(scene.instances.count).enumerated()
            where scene.instances[index].params.y == KIND_EFFECT {
            let border = Self.headerSize + index * MemoryLayout<RenderInstance>.stride + 3 * MemoryLayout<SIMD4<Float>>.stride
            destination.storeBytes(of: Float(mark & 0xffff), toByteOffset: border, as: Float.self)
            destination.storeBytes(of: Float(mark >> 16), toByteOffset: border + 4, as: Float.self)
        }
        if let sequence { withUnsafeBytes(of: sequence, append) }
        func appendAtlas(_ update: WebAtlasUpdate, texels: [UInt8], width: Int, channels: Int) {
            switch update {
            case .none: break
            case .full: texels.withUnsafeBytes(append)
            case .patch(let edges):
                let w = edges.z - edges.x, h = edges.w - edges.y
                let geometry = SIMD4(UInt32(edges.x), UInt32(edges.y), UInt32(w), UInt32(h))
                withUnsafeBytes(of: geometry, append)
                texels.withUnsafeBytes { source in
                    for row in edges.y..<edges.w {
                        let start = (row * width + edges.x) * channels
                        append(UnsafeRawBufferPointer(rebasing: source[start ..< start + w * channels]))
                    }
                }
            }
        }
        appendAtlas(glyphUpdate, texels: scene.glyphs.texels, width: scene.glyphs.width, channels: 1)
        appendAtlas(imageUpdate, texels: scene.images.texels, width: scene.images.width, channels: 4)
        surfaces.bytes.withUnsafeBytes(append)
        assert(offset == byteCount)
    }
}
