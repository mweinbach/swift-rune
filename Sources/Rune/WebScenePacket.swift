import Foundation
import RuneRef

/// Binary scene shared with rune-webgl.mjs. WASI runs little-endian; the header is 14 32-bit words.
struct WebScenePacket {
    static let magic: UInt32 = 0x32475352 // RSG2
    static let pagedMagic: UInt32 = 0x33475352 // RSG3
    static let headerSize = 56
    let scene: RenderFrame
    let glyphUpdate: WebAtlasUpdate
    let imageUpdate: WebAtlasUpdate
    let pageUpdates: [WebAtlasUpdate]?
    let glyphTransfers: (pages: [R8Atlas], updates: [WebAtlasUpdate])?
    let sequence: SIMD2<UInt32>?
    let byteCount: Int
    let surfaces: WebSurfacePacket

    init?(scene: RenderFrame, sendGlyphs: Bool, sendImages: Bool,
          surfaceCache: WebSurfacePacket.Cache = .init()) throws {
        try self.init(scene: scene, glyphUpdate: sendGlyphs ? .full : .none,
                      imageUpdate: sendImages ? .full : .none, sequence: nil, surfaceCache: surfaceCache)
    }

    init?(scene: RenderFrame, glyphUpdate: WebAtlasUpdate, imageUpdate: WebAtlasUpdate,
          sequence: SIMD2<UInt32>?, pageUpdates: [WebAtlasUpdate]? = nil, glyphTransfers: (pages: [R8Atlas], updates: [WebAtlasUpdate])? = nil,
          surfaceCache: WebSurfacePacket.Cache = .init()) throws {
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
        func pageBytes<Page: WebAtlasPixels>(_ pages: [Page], _ updates: [WebAtlasUpdate]) -> Int? {
            guard !pages.isEmpty, pages.count == updates.count, UInt32(exactly: pages.count) != nil else { return nil }
            var total = 0
            for (page, update) in zip(pages, updates) {
                let count = length(update, texelBytes: page.texels.count, channels: Page.webChannels)
                guard total <= Int.max - 12, count <= Int.max - 12 - total else { return nil }
                total += 12 + count
            }
            return total
        }
        let imageBytes: Int
        if let pageUpdates {
            guard sequence != nil, imageUpdate == .none, let bytes = pageBytes(scene.webImagePages, pageUpdates) else { return nil }
            imageBytes = bytes
        } else {
            imageBytes = length(imageUpdate, texelBytes: scene.images.texels.count, channels: 4)
        }
        let glyphBytes: Int
        if let glyphTransfers {
            guard pageUpdates != nil, glyphUpdate == .none,
                  let bytes = pageBytes(glyphTransfers.pages, glyphTransfers.updates) else { return nil }
            glyphBytes = bytes
        } else {
            glyphBytes = glyphUpdate == .none ? 0 : length(glyphUpdate, texelBytes: scene.glyphs.texels.count, channels: 1)
        }
        var size = Self.headerSize + (sequence == nil ? 0 : 8)
        for fieldSize in [bytes, glyphBytes, imageBytes, surfaces.bytes.count] {
            let (sum, tooLarge) = size.addingReportingOverflow(fieldSize)
            guard !tooLarge else { return nil }
            size = sum
        }
        self.scene = scene
        self.glyphUpdate = glyphUpdate
        self.imageUpdate = imageUpdate
        self.pageUpdates = pageUpdates
        self.glyphTransfers = glyphTransfers
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
        let sceneFlags: UInt32 = (scene.srgbBlend ? 1 : 0) | flags(for: glyphUpdate, full: 2, patch: 8)
            | flags(for: imageUpdate, full: 4, patch: 16) | (sequence == nil ? 0 : 32) | (glyphTransfers == nil ? 0 : 128)
        let header: [UInt32] = [
            pageUpdates == nil ? Self.magic : Self.pagedMagic, UInt32(scene.width), UInt32(scene.height), sceneFlags, UInt32(scene.instances.count),
            UInt32(glyphTransfers?.pages.count ?? scene.baseGlyphAtlas.width), glyphTransfers == nil ? UInt32(scene.baseGlyphAtlas.height) : 0,
            UInt32(pageUpdates?.count ?? scene.images.width), pageUpdates == nil ? UInt32(scene.images.height) : 0,
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
        func appendPages<Page: WebAtlasPixels>(_ pages: [Page], _ updates: [WebAtlasUpdate]) {
            for (page, update) in zip(pages, updates) {
                let vacant = page.texels.isEmpty
                let header = [vacant ? 0 : UInt32(page.width), vacant ? 0 : UInt32(page.height),
                              flags(for: update, full: 1, patch: 2)]
                header.withUnsafeBytes(append)
                appendAtlas(update, texels: page.texels, width: page.width, channels: Page.webChannels)
            }
        }
        if let glyphTransfers {
            appendPages(glyphTransfers.pages, glyphTransfers.updates)
        } else if glyphUpdate != .none {
            let glyphs = scene.glyphs
            appendAtlas(glyphUpdate, texels: glyphs.texels, width: glyphs.width, channels: 1)
        }
        if let pageUpdates {
            appendPages(scene.webImagePages, pageUpdates)
        } else {
            appendAtlas(imageUpdate, texels: scene.images.texels, width: scene.images.width, channels: 4)
        }
        surfaces.bytes.withUnsafeBytes(append)
        assert(offset == byteCount)
    }
}
